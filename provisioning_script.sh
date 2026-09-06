#!/bin/bash
# ============================================================================
# provisioning_script for Character Dataset Generation (FLUX + PuLID + Redux)
# ใช้กับ Vast.ai ผ่าน PROVISIONING_SCRIPT
# ============================================================================

set -eo pipefail

# ----------------------------------------------------------------------------
# ส่วนที่ 0: หา path จริงของ ComfyUI บนเครื่องนี้
# ----------------------------------------------------------------------------
echo ">>> กำลังค้นหาโฟลเดอร์ ComfyUI บนเครื่องนี้..."
COMFY_DIR=$(find / -maxdepth 5 -iname "ComfyUI" -type d 2>/dev/null -print -quit)

if [ -z "$COMFY_DIR" ]; then
  COMFY_DIR="/workspace/ComfyUI"
  echo ">>> ไม่เจอโฟลเดอร์ที่มีอยู่แล้ว จะใช้ path เริ่มต้น: $COMFY_DIR"
else
  echo ">>> เจอ ComfyUI ที่: $COMFY_DIR"
fi

MODELS_DIR="$COMFY_DIR/models"
CUSTOM_NODES_DIR="$COMFY_DIR/custom_nodes"

# สร้างโฟลเดอร์ที่จำเป็น
mkdir -p "$MODELS_DIR/unet"
mkdir -p "$MODELS_DIR/clip"
mkdir -p "$MODELS_DIR/vae"
mkdir -p "$MODELS_DIR/pulid"
mkdir -p "$MODELS_DIR/style_models"
mkdir -p "$MODELS_DIR/clip_vision"
mkdir -p "$MODELS_DIR/insightface/models"
mkdir -p "$COMFY_DIR/user/default/workflows"
mkdir -p "$CUSTOM_NODES_DIR"

# ----------------------------------------------------------------------------
# ฟังก์ชันช่วยโหลดไฟล์ + ข้ามถ้ามีอยู่แล้ว (กันโหลดซ้ำถ้ารันสคริปต์ซ้ำ)
# ----------------------------------------------------------------------------
download_if_missing() {
  local url="$1"
  local dest="$2"
  if [ -f "$dest" ]; then
    echo ">>> ข้ามไป (มีไฟล์อยู่แล้ว): $(basename "$dest")"
    return
  fi
  echo ">>> กำลังโหลด: $(basename "$dest")"
  wget -q --show-progress -O "$dest" "$url"
  echo ">>> เสร็จแล้ว: $dest"
}
# ====================== โมเดลหลัก ======================
# ส่วนที่ 1: UNET —> FLUX Dev —> FP8 flux1-dev-fp8.safetensors
download_if_missing \
  "https://huggingface.co/Comfy-Org/flux1-dev/resolve/main/flux1-dev-fp8.safetensors" \
  "$MODELS_DIR/unet/flux1-dev-fp8.safetensors"
# ----------------------------------------------------------------------------
# ส่วนที่ 2: Text Encoder —> clip_l.safetensors , t5xxl_fp8_e4m3fn.safetensors
download_if_missing \
  "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors" \
  "$MODELS_DIR/clip/clip_l.safetensors"
download_if_missing \
  "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp8_e4m3fn.safetensors" \
  "$MODELS_DIR/clip/t5xxl_fp8_e4m3fn.safetensors"
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
# ส่วนที่ 5: FLUX Redux —> flux1-redux-dev.safetensors
download_if_missing \
  "https://huggingface.co/black-forest-labs/FLUX.1-Redux-dev/resolve/main/flux1-redux-dev.safetensors" \
  "$MODELS_DIR/style_models/flux1-redux-dev.safetensors"
# ----------------------------------------------------------------------------
# ส่วนที่ 6: SigCLIP Vision (สำหรับ Redux) —> sigclip_vision_patch14_384.safetensors
download_if_missing \
  "https://huggingface.co/Comfy-Org/sigclip_vision_384/resolve/main/sigclip_vision_patch14_384.safetensors" \
  "$MODELS_DIR/clip_vision/sigclip_vision_patch14_384.safetensors"
# ----------------------------------------------------------------------------
# ส่วนที่ 7: ติดตั้ง Custom Node ที่จำเป็น
install_node() {
  local name="$1"
  local repo="$2"
  if [ -d "$CUSTOM_NODES_DIR/$name" ]; then
    echo ">>> $name มีอยู่แล้ว ข้าม"
  else
    echo ">>> กำลังติดตั้ง $name"
    git clone "$repo" "$CUSTOM_NODES_DIR/$name"
    if [ -f "$CUSTOM_NODES_DIR/$name/requirements.txt" ]; then
      pip install -r "$CUSTOM_NODES_DIR/$name/requirements.txt" --break-system-packages || true
    fi
  fi
}

install_node "ComfyUI-PuLID-Flux" "https://github.com/balazik/ComfyUI-PuLID-Flux.git"
install_node "ComfyUI-KJNodes" "https://github.com/kijai/ComfyUI-KJNodes.git"
install_node "rgthree-comfy" "https://github.com/rgthree/rgthree-comfy.git"
install_node "ComfyUI-Impact-Pack" "https://github.com/ltdrdata/ComfyUI-Impact-Pack.git"

echo "============================================================"
echo "โหลดโมเดล + Custom Nodes สำหรับสร้าง Character Dataset เสร็จแล้ว"
echo "ComfyUI path: $COMFY_DIR"
echo "============================================================"
# ----------------------------------------------------------------------------
# ส่วนที่ 8: โหลด Workflow ตัวอย่าง (text-to-music พื้นฐาน)
# ----------------------------------------------------------------------------
# ไม่ได้ใช้download_if_missing \
# ไม่ได้ใช้  "https://raw.githubusercontent.com/ryanontheinside/ComfyUI_RyanOnTheInside/main/examples/ace1.5/audio_ace_step_1_5_cover.json" \
# ไม่ได้ใช้  "$COMFY_DIR/user/default/workflows/audio_ace_step_1_5_cover.json"
# ----------------------------------------------------------------------------
# เสร็จสิ้น
# ----------------------------------------------------------------------------
# ไม่ได้ใช้echo "============================================================"
# ไม่ได้ใช้echo "โหลดโมเดล + Custom Nodes + Workflowทดสอบ สำหรับสร้าง Character Dataset เสร็จแล้ว"
# ไม่ได้ใช้echo "ComfyUI path: $COMFY_DIR"
# ไม่ได้ใช้echo "============================================================"
echo "============================================================"
# ----------------------------------------------------------------------------
# แก้ไขปัญหา Illegal instruction จาก kornia_rs บน CPU เก่า
# ----------------------------------------------------------------------------
echo "echo "=============================>>> กำลังแก้ไข kornia เพื่อป้องกัน Illegal instruction... ============================="
pip uninstall -y kornia kornia_rs || true
pip install kornia==0.7.3 --break-system-packages
echo "============================================================"
echo ">>> ติดตั้ง kornia==0.7.3 เสร็จแล้ว"
echo "============================================================"
