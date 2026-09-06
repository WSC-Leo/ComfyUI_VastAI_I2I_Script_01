#!/bin/bash
# ============================================================================
# provisioning_ace_step_xl.sh
# ใช้กับ Vast.AI ผ่าน environment variable "PROVISIONING_SCRIPT"
# โหลดโมเดล ACE-Step 1.5 XL (turbo) + text encoder + VAE + workflow + custom
# node ที่จำเป็น สำหรับสร้างเพลง Lofi/Piano ลง YouTube
# ไม่ต้องใช้ HF_TOKEN — repo นี้ไม่ gated
# ============================================================================

set -eo pipefail

# ----------------------------------------------------------------------------
# ส่วนที่ 0: หา path จริงของ ComfyUI บนเครื่องนี้
# ----------------------------------------------------------------------------
echo ">>> กำลังค้นหาโฟลเดอร์ ComfyUI บนเครื่องนี้..."
COMFY_DIR=$(find / -maxdepth 5 -iname "ComfyUI" -type d 2>/dev/null | head -n 1)

if [ -z "$COMFY_DIR" ]; then
  COMFY_DIR="/workspace/ComfyUI"
  echo ">>> ไม่เจอโฟลเดอร์ที่มีอยู่แล้ว จะใช้ path เริ่มต้น: $COMFY_DIR"
else
  echo ">>> เจอ ComfyUI ที่: $COMFY_DIR"
fi

MODELS_DIR="$COMFY_DIR/models"

mkdir -p "$MODELS_DIR/diffusion_models"
mkdir -p "$MODELS_DIR/text_encoders"
mkdir -p "$MODELS_DIR/vae"
mkdir -p "$MODELS_DIR/pulid"
mkdir -p "$MODELS_DIR/style_models"
mkdir -p "$MODELS_DIR/clip_vision"
mkdir -p "$COMFY_DIR/user/default/workflows"
mkdir -p "$COMFY_DIR/custom_nodes"

# ----------------------------------------------------------------------------
# ฟังก์ชันช่วยโหลดไฟล์ + ข้ามถ้ามีอยู่แล้ว (กันโหลดซ้ำถ้ารันสคริปต์ซ้ำ)
# ----------------------------------------------------------------------------
download_if_missing() {
  local url="$1"
  local dest="$2"

  if [ -f "$dest" ]; then
    echo ">>> ข้ามไป (มีไฟล์อยู่แล้ว): $dest"
    return
  fi

  echo ">>> กำลังโหลด: $(basename "$dest")"
  wget -q --show-progress -O "$dest" "$url"
  echo ">>> เสร็จแล้ว: $dest"
}

# ----------------------------------------------------------------------------
# ส่วนที่ 1: UNET —> FLUX Dev —> FP8 flux1-dev-fp8.safetensors
download_if_missing \
  "https://huggingface.co/Comfy-Org/flux1-dev/resolve/main/flux1-dev-fp8.safetensors" \
  "$MODELS_DIR/unet/flux1-dev-fp8.safetensors"

# ----------------------------------------------------------------------------
# ส่วนที่ 2: Text Encoder —> clip_l.safetensors , t5xxl_fp8_e4m3fn.safetensors
download_if_missing \
  "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors" \
  "$MODELS_DIR/text_encoders/clip_l.safetensors"
download_if_missing \
  "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp8_e4m3fn.safetensors" \
  "$MODELS_DIR/text_encoders/t5xxl_fp8_e4m3fn.safetensors"
  
# ----------------------------------------------------------------------------
# ส่วนที่ 3: VAE —> ae.safetensors
download_if_missing \
  "https://huggingface.co/black-forest-labs/FLUX.1-dev/resolve/main/ae.safetensors" \
  "$MODELS_DIR/vae/ae.safetensors"

# ----------------------------------------------------------------------------
# ส่วนที่ 4: PuLID for FLUX (สำคัญมากสำหรับล็อคใบหน้า) —> pulid_flux_v0.9.1.safetensors
download_if_missing \
  "https://huggingface.co/guozinan/PuLID/resolve/main/pulid_flux_v0.9.1.safetensors" \
  "$MODELS_DIR/pulid/pulid_flux_v0.9.1.safetensors"

# ----------------------------------------------------------------------------
# ส่วนที่ 5: FLUX Redux —> pulid_flux_v0.9.1.safetensors
download_if_missing \
  "https://huggingface.co/black-forest-labs/FLUX.1-Redux-dev/resolve/main/flux1-redux-dev.safetensors" \
  "$MODELS_DIR/style_models/flux1-redux-dev.safetensors"

# ----------------------------------------------------------------------------
# ส่วนที่ 6: SigCLIP Vision (สำหรับ Redux) —> pulid_flux_v0.9.1.safetensors
download_if_missing \
  "https://huggingface.co/Comfy-Org/sigclip_vision_384/resolve/main/sigclip_vision_patch14_384.safetensors" \
  "$MODELS_DIR/clip_vision/sigclip_vision_patch14_384.safetensors"

# ----------------------------------------------------------------------------
# ส่วนที่ 4: ติดตั้ง Custom Node ที่จำเป็นสำหรับ ACE-Step ใน ComfyUI
# ----------------------------------------------------------------------------
CUSTOM_NODES_DIR="$COMFY_DIR/custom_nodes"

if [ -d "$CUSTOM_NODES_DIR/ComfyUI_RyanOnTheInside" ]; then
  echo ">>> custom node ComfyUI_RyanOnTheInside มีอยู่แล้ว ข้ามการติดตั้ง"
else
  echo ">>> กำลังติดตั้ง custom node: ComfyUI_RyanOnTheInside"
  git clone https://github.com/ryanontheinside/ComfyUI_RyanOnTheInside.git \
    "$CUSTOM_NODES_DIR/ComfyUI_RyanOnTheInside"

  if [ -f "$CUSTOM_NODES_DIR/ComfyUI_RyanOnTheInside/requirements.txt" ]; then
    pip install -r "$CUSTOM_NODES_DIR/ComfyUI_RyanOnTheInside/requirements.txt" --break-system-packages
  fi
fi

# ----------------------------------------------------------------------------
# ส่วนที่ 5: โหลด Workflow ตัวอย่าง (text-to-music พื้นฐาน)
# ----------------------------------------------------------------------------
download_if_missing \
  "https://raw.githubusercontent.com/ryanontheinside/ComfyUI_RyanOnTheInside/main/examples/ace1.5/audio_ace_step_1_5_cover.json" \
  "$COMFY_DIR/user/default/workflows/audio_ace_step_1_5_cover.json"

# ----------------------------------------------------------------------------
# เสร็จสิ้น
# ----------------------------------------------------------------------------
echo "============================================================"
echo "โหลดโมเดล ACE-Step 1.5 XL (turbo) + text encoder + VAE"
echo "+ custom node + workflow ครบแล้ว"
echo "ComfyUI path: $COMFY_DIR"
echo "============================================================"
