#!/bin/bash
# ==============================================================================
# Retrying Reservations Script
#
# An automated, resilient capacity acquisition script for Google Cloud Compute
# Engine zonal reservations. Progressively creates and upsizes a reservation in
# single-VM increments until the desired capacity is fully satisfied.
#
# Command format:
#   retrying-reservations.sh <reservation-name> <project-id> <zone> <vm-type> <vm-count>
#
# Examples:
#   # 1. Standard instance reservation:
#   ./retrying-reservations.sh my-reservation my-gcp-project us-central1-a "n2-standard-8" 10
#
#   # 2. Reservation with an automated self-deletion timestamp:
#   ./retrying-reservations.sh my-reservation my-gcp-project us-central1-a "n2-standard-8 --delete-at-time=2026-12-31T23:59:00.000Z" 10
#
#   # 3. Reservation with attached GPU accelerators:
#   ./retrying-reservations.sh my-reservation my-gcp-project us-central1-a "n1-standard-64 --accelerator=count=4,type=nvidia-tesla-t4" 10
# ==============================================================================

# Input Parameters
NAME="$1"
PROJECT="$2"
ZONE="$3"
VM_TYPE="$4"
VM_COUNT="$5"

# Operational Defaults (can be customized via environment variables)
RETRY_RATE="${RETRY_RATE:-60}"
INCREMENT="${INCREMENT:-1}"
GCLOUD="${GCLOUD_BIN:-$(command -v gcloud 2>/dev/null || echo "/usr/bin/gcloud")}"

# Validate command-line arguments
if [[ -z "$NAME" || -z "$PROJECT" || -z "$ZONE" || -z "$VM_TYPE" || -z "$VM_COUNT" ]]; then
  echo "Error: Missing required arguments."
  echo ""
  echo "Usage:"
  echo "  $0 <reservation-name> <project-id> <zone> <vm-type> <vm-count>"
  echo ""
  echo "Examples:"
  echo "  $0 my-reservation my-gcp-project us-central1-a \"n2-standard-8\" 10"
  echo "  $0 my-reservation my-gcp-project us-central1-a \"n2-standard-8 --delete-at-time=2026-12-31T23:59:00.000Z\" 10"
  echo "  $0 my-reservation my-gcp-project us-central1-a \"n1-standard-64 --accelerator=count=4,type=nvidia-tesla-t4\" 10"
  exit 1
fi

if ! [[ "$VM_COUNT" =~ ^[0-9]+$ ]] || [[ "$VM_COUNT" -le 0 ]]; then
  echo "Error: <vm-count> must be a positive integer. Provided: '$VM_COUNT'"
  exit 1
fi

echo "=========================================================="
echo " GCP Retrying Reservations"
echo "=========================================================="
echo " Reservation Name : $NAME"
echo " Project ID       : $PROJECT"
echo " Zone             : $ZONE"
echo " Machine Spec     : $VM_TYPE"
echo " Target VM Count  : $VM_COUNT"
echo " Retry Interval   : ${RETRY_RATE}s"
echo " Step Increment   : $INCREMENT"
echo " gcloud Binary    : $GCLOUD"
echo "=========================================================="

# Check for existing reservation
EXISTING_RESERVATIONS=$($GCLOUD beta compute reservations describe "$NAME" --project="$PROJECT" --zone="$ZONE" --format='get(specificReservation.assured_count)' 2>/dev/null)
EXISTING_RES_CODE=$?

if [[ $EXISTING_RES_CODE -ne 0 ]]; then
  echo "No existing reservation found. Creating new reservation..."
  EXISTING_RESERVATIONS=0
else
  echo "Found existing reservation '$NAME' with $EXISTING_RESERVATIONS assured instance(s)."
fi

# Main acquisition loop
while true; do

  # Attempt initial reservation creation if it does not yet exist
  if [[ $EXISTING_RES_CODE -ne 0 ]] && [[ $EXISTING_RESERVATIONS -eq 0 ]]; then
    echo "Attempting to create reservation '$NAME' with initial count of 1..."
    # Intentionally unquoted $VM_TYPE allows passing additional flags (e.g., --delete-at-time, --accelerator)
    # shellcheck disable=SC2086
    $GCLOUD beta compute reservations create "$NAME" --project="$PROJECT" --zone="$ZONE" --machine-type=$VM_TYPE --vm-count=1 2>/dev/null
    CREATE_STATUS=$?

    if [[ $CREATE_STATUS -eq 0 ]]; then
      echo "Successfully created reservation '$NAME'."
      EXISTING_RES_CODE=0
      EXISTING_RESERVATIONS=$($GCLOUD beta compute reservations describe "$NAME" --project="$PROJECT" --zone="$ZONE" --format='get(specificReservation.assured_count)' 2>/dev/null)
    else
      echo "Failed to create reservation. Capacity may be unavailable."
    fi
  fi

  # Attempt incremental upsizing if reservation exists and count is below target
  if [[ $EXISTING_RES_CODE -eq 0 ]] && [[ $EXISTING_RESERVATIONS -lt $VM_COUNT ]]; then
    echo "Current reservation count: $EXISTING_RESERVATIONS (Target: $VM_COUNT)"

    while [[ $EXISTING_RESERVATIONS -lt $VM_COUNT ]]; do
      NEW_TARGET=$((EXISTING_RESERVATIONS + INCREMENT))
      if [[ $NEW_TARGET -gt $VM_COUNT ]]; then
        NEW_TARGET=$VM_COUNT
      fi

      echo "Attempting to upsize reservation from $EXISTING_RESERVATIONS to $NEW_TARGET..."
      $GCLOUD beta compute reservations update "$NAME" --zone="$ZONE" --project="$PROJECT" --vm-count="$NEW_TARGET" 2>/dev/null
      UPSIZE_STATUS=$?

      if [[ $UPSIZE_STATUS -eq 0 ]]; then
        echo "Successfully upsized reservation."
        EXISTING_RESERVATIONS=$($GCLOUD beta compute reservations describe "$NAME" --project="$PROJECT" --zone="$ZONE" --format='get(specificReservation.assured_count)' 2>/dev/null)
        echo "Confirmed reservation count: $EXISTING_RESERVATIONS"

        if [[ $EXISTING_RESERVATIONS -ge $VM_COUNT ]]; then
          echo "Desired reservation count ($VM_COUNT) reached. Successfully completed!"
          exit 0
        fi
      else
        echo "Failed to upsize reservation. Zonal pool may currently be constrained."
        break
      fi
    done
  fi

  # Evaluate termination or pause for retry
  if [[ $EXISTING_RESERVATIONS -ge $VM_COUNT ]]; then
    echo "Desired reservation count ($VM_COUNT) reached. Successfully completed!"
    exit 0
  else
    echo "Retrying in ${RETRY_RATE} seconds..."
    sleep "$RETRY_RATE"
  fi

done
