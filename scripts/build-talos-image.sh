#!/usr/bin/env bash
# Builds customized Talos boot assets for AWS AMI and/or PXE boot.
# Requirements: docker, crane (github.com/google/go-containerregistry), curl, python3
# Optional (--import-aws): aws CLI with ec2 and s3 permissions
#
# Usage:
#   ./scripts/build-talos-image.sh [OPTIONS]
#
# Options:
#   -v, --version VERSION      Talos version to build (default: v1.13.5)
#       --image-file FILE      Schematic YAML to build from (default: node-config/image.yaml)
#       --target TARGET        What to build: aws | pxe | all  (default: aws)
#       --import-aws           Import AWS image to AWS as an AMI (requires --target aws|all)
#       --s3-bucket BUCKET     S3 bucket for staging the image (required with --import-aws)
#       --region REGION        AWS region (default: ap-east-2)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NODE_CONFIG_DIR="$REPO_ROOT/node-config"

TALOS_VERSION="${TALOS_VERSION:-v1.13.5}"
ARCH="amd64"
TARGET="aws"
IMPORT_AWS=false
S3_BUCKET=""
AWS_REGION="ap-east-2"
AWS_PROFILE="${AWS_PROFILE:-default}"
IMAGE_FILE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    -v|--version)   TALOS_VERSION="$2"; shift 2 ;;
    --image-file)   IMAGE_FILE="$2"; shift 2 ;;
    --target)       TARGET="$2"; shift 2 ;;
    --import-aws)   IMPORT_AWS=true; shift ;;
    --s3-bucket)    S3_BUCKET="$2"; shift 2 ;;
    --region)       AWS_REGION="$2"; shift 2 ;;
    --profile)      AWS_PROFILE="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

IMAGE_FILE="${IMAGE_FILE:-$NODE_CONFIG_DIR/image.yaml}"
MANIFEST_LABEL="$(basename "$IMAGE_FILE" .yaml)"

if [[ "$TARGET" != "aws" && "$TARGET" != "pxe" && "$TARGET" != "all" ]]; then
  echo "ERROR: --target must be one of: aws, pxe, all" >&2
  exit 1
fi

if [[ "$IMPORT_AWS" == "true" && "$TARGET" == "pxe" ]]; then
  echo "ERROR: --import-aws requires --target aws or --target all" >&2
  exit 1
fi

SCHEMATIC_FILE="$IMAGE_FILE"

EXTENSIONS=()
while IFS= read -r ext; do
  EXTENSIONS+=("$ext")
done <<< "$(grep -E '^\s+- siderolabs/' "$SCHEMATIC_FILE" | awk '{print $2}')"

log()  { echo "==> $*"; }
step() { echo "--- $*"; }

log "Talos image build — version ${TALOS_VERSION}, manifest: ${MANIFEST_LABEL}, target: ${TARGET}, arch: ${ARCH}"
echo ""

# ---------------------------------------------------------------------------
# Step 1: Upload schematic to Image Factory → get canonical schematic ID
# ---------------------------------------------------------------------------
step "Uploading schematic to Image Factory"
SCHEMATIC_RESPONSE=$(curl -sS -f -X POST \
  --data-binary "@${SCHEMATIC_FILE}" \
  https://factory.talos.dev/schematics)

SCHEMATIC_ID=$(python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" <<< "$SCHEMATIC_RESPONSE")
echo "    ID: ${SCHEMATIC_ID}"
printf '%s\n' "$SCHEMATIC_RESPONSE" > "${NODE_CONFIG_DIR}/image_schematic.json"
echo ""

# ---------------------------------------------------------------------------
# Step 2: Resolve pinned extension image references for this Talos version
# ---------------------------------------------------------------------------
step "Resolving extension image digests (extensions:${TALOS_VERSION})"
IMAGE_DIGESTS=$(crane export "ghcr.io/siderolabs/extensions:${TALOS_VERSION}" | tar x -O image-digests)

EXTENSION_FLAGS=()
for EXT in "${EXTENSIONS[@]}"; do
  EXT_NAME="${EXT#siderolabs/}"
  DIGEST_LINE=$(grep "^ghcr.io/siderolabs/${EXT_NAME}:" <<< "$IMAGE_DIGESTS" | head -1 || true)
  if [[ -z "$DIGEST_LINE" ]]; then
    echo "ERROR: No digest found for extension '${EXT}' in extensions:${TALOS_VERSION}" >&2
    exit 1
  fi
  DIGEST=$(grep -o '@sha256:[a-f0-9]*' <<< "$DIGEST_LINE" || true)
  echo "    ${EXT}: ${DIGEST}"
  EXTENSION_FLAGS+=(--system-extension-image "${DIGEST_LINE}")
done
echo ""

# ---------------------------------------------------------------------------
# Build functions
# ---------------------------------------------------------------------------

build_aws() {
  local imager_out="$NODE_CONFIG_DIR/_out/aws-${ARCH}.raw.zst"
  local out="$NODE_CONFIG_DIR/_out/${MANIFEST_LABEL}-aws-${ARCH}.raw.zst"
  step "Building AWS disk image"
  docker run --rm -t \
    -v "${NODE_CONFIG_DIR}/_out:/out" \
    "ghcr.io/siderolabs/imager:${TALOS_VERSION}" \
    aws \
    --arch "${ARCH}" \
    "${EXTENSION_FLAGS[@]}"

  if [[ ! -f "$imager_out" ]]; then
    echo "ERROR: Expected image not found: ${imager_out}" >&2
    exit 1
  fi
  mv "$imager_out" "$out"
  log "AWS image built: ${out} ($(ls -lh "$out" | awk '{print $5}'))"
  echo ""
}

build_pxe() {
  local kernel_out="$NODE_CONFIG_DIR/_out/kernel-${ARCH}"
  local initramfs_out="$NODE_CONFIG_DIR/_out/initramfs-${ARCH}.xz"

  step "Building PXE kernel"
  docker run --rm -t \
    -v "${NODE_CONFIG_DIR}_out:/out" \
    "ghcr.io/siderolabs/imager:${TALOS_VERSION}" \
    iso \
    --arch "${ARCH}" \
    --output-kind kernel

  if [[ ! -f "$kernel_out" ]]; then
    echo "ERROR: Expected kernel not found: ${kernel_out}" >&2
    exit 1
  fi
  echo "    Kernel: ${kernel_out} ($(ls -lh "$kernel_out" | awk '{print $5}'))"
  echo ""

  step "Building PXE initramfs (with extensions)"
  docker run --rm -t \
    -v "${NODE_CONFIG_DIR}/_out:/out" \
    "ghcr.io/siderolabs/imager:${TALOS_VERSION}" \
    iso \
    --arch "${ARCH}" \
    --output-kind initramfs \
    "${EXTENSION_FLAGS[@]}"

  if [[ ! -f "$initramfs_out" ]]; then
    echo "ERROR: Expected initramfs not found: ${initramfs_out}" >&2
    exit 1
  fi
  echo "    Initramfs: ${initramfs_out} ($(ls -lh "$initramfs_out" | awk '{print $5}'))"
  log "PXE assets built."
  echo ""
}

import_aws_ami() {
  local image="$NODE_CONFIG_DIR/_out/${MANIFEST_LABEL}-aws-${ARCH}.raw.zst"

  if [[ -z "$S3_BUCKET" ]]; then
    echo "ERROR: --s3-bucket is required when using --import-aws" >&2
    exit 1
  fi

  local raw_image="${image%.zst}"
  local s3_key="talos-images/talos-${TALOS_VERSION}-${SCHEMATIC_ID:0:12}-${MANIFEST_LABEL}-aws-${ARCH}.raw"

  step "Decompressing image (zstd → raw)"
  zstd -d "$image" -o "$raw_image" --force
  echo "    Output: ${raw_image} ($(ls -lh "$raw_image" | awk '{print $5}'))"
  echo ""

  step "Uploading image to s3://${S3_BUCKET}/${s3_key}"
  aws s3 cp "$raw_image" "s3://${S3_BUCKET}/${s3_key}" \
    --region "$AWS_REGION" \
    --profile "$AWS_PROFILE"
  rm -f "$raw_image"
  echo ""

  step "Importing EBS snapshot"
  local import_task
  import_task=$(aws ec2 import-snapshot \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --description "Talos ${TALOS_VERSION} aws/${ARCH} schematic=${SCHEMATIC_ID:0:12}" \
    --disk-container "Format=RAW,UserBucket={S3Bucket=${S3_BUCKET},S3Key=${s3_key}}" \
    --output json)
  local task_id
  task_id=$(python3 -c "import sys,json; print(json.load(sys.stdin)['ImportTaskId'])" <<< "$import_task")
  echo "    Import task: ${task_id}"

  step "Waiting for snapshot import to complete (polls every 30s)"
  local snapshot_id state progress task_status task_detail
  while true; do
    task_status=$(aws ec2 describe-import-snapshot-tasks \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" \
      --import-task-ids "$task_id" \
      --output json)
    task_detail=$(python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['ImportSnapshotTasks'][0]['SnapshotTaskDetail']))" <<< "$task_status")
    state=$(python3 -c "import sys,json; print(json.load(sys.stdin)['Status'])" <<< "$task_detail")
    progress=$(python3 -c "import sys,json; print(json.load(sys.stdin).get('Progress',''))" <<< "$task_detail")
    echo "    State: ${state}${progress:+ (${progress}%)}"

    if [[ "$state" == "completed" ]]; then
      snapshot_id=$(python3 -c "import sys,json; print(json.load(sys.stdin)['SnapshotId'])" <<< "$task_detail")
      break
    elif [[ "$state" == "deleted" || "$state" == "deleting" ]]; then
      local msg
      msg=$(python3 -c "import sys,json; print(json.load(sys.stdin).get('StatusMessage',''))" <<< "$task_detail")
      echo "ERROR: Snapshot import failed: ${msg}" >&2
      exit 1
    fi
    sleep 30
  done
  echo "    Snapshot: ${snapshot_id}"
  echo ""

  step "Registering AMI"
  local ami_name="talos-${TALOS_VERSION}-${SCHEMATIC_ID:0:12}-${MANIFEST_LABEL}-${ARCH}"
  local ami_result ami_id
  ami_result=$(aws ec2 register-image \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --name "$ami_name" \
    --description "Talos ${TALOS_VERSION} schematic=${SCHEMATIC_ID:0:12} ${MANIFEST_LABEL} ${ARCH}" \
    --architecture x86_64 \
    --virtualization-type hvm \
    --boot-mode uefi \
    --root-device-name /dev/xvda \
    --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"SnapshotId\":\"${snapshot_id}\",\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
    --ena-support \
    --output json)
  ami_id=$(python3 -c "import sys,json; print(json.load(sys.stdin)['ImageId'])" <<< "$ami_result")

  log "AMI registered: ${ami_id} (${ami_name})"
  echo ""
  echo "    Update test.tfvars.json — add/update the entry for this manifest (${MANIFEST_LABEL}):"
  echo "      \"talos_ami\": \"${ami_id}\""
  echo ""
}

# ---------------------------------------------------------------------------
# Run selected targets
# ---------------------------------------------------------------------------

if [[ "$TARGET" == "aws" || "$TARGET" == "all" ]]; then
  build_aws
fi

if [[ "$TARGET" == "pxe" || "$TARGET" == "all" ]]; then
  build_pxe
fi

if [[ "$IMPORT_AWS" == "true" ]]; then
  import_aws_ami
fi

log "Done."
