#!/bin/bash
# ============================================================================
# provisioning_script for Character Dataset Generation (FLUX + PuLID + Redux)
# ใช้กับ Vast.ai ผ่าน PROVISIONING_SCRIPT
# แก้ไขจากปัญหาที่เจอวันที่ 06/09/2026:
#   1. Repo PuLID ผิดตัว (balazik -> ต้องเป็น lldacing/ComfyUI_PuLID_Flux_ll)
#   2. ขาด dependency: facenet_pytorch, insightface, onnxruntime-gpu, facexlib
#   3. ขาดการโหลดโมเดล EVA-CLIP และ antelopev2 (insightface) ของ PuLID
#   4. set -eo pipefail ทำให้ wget สะดุดแล้วสคริปต์ตายทั้งไฟล์ -> เปลี่ยนเป็น
#      continue-on-error ต่อรายการ + สรุปท้ายว่าอะไรขาดบ้าง
#   5. ไม่มี guard ป้องกัน torch ถูก downgrade ตอนลง dependency ของ custom node
#      (facenet-pytorch ธรรมดาจะดึง torch<2.3.0 มาทับ torch 2.10.0+cu130 ของ template)
# ============================================================================

# หมายเหตุ: ไม่ใช้ set -e แล้ว เพื่อไม่ให้ error รายการเดียวฆ่าทั้งสคริปต์
set -uo pipefail

FAILED_LOG="/workspace/provisioning_failed.log"
> "$FAILED_LOG"

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

# หา python/pip ของ venv ที่ ComfyUI ใช้จริง (กันปัญหา pip ผิด env)
PYTHON_BIN="python3"
PIP_BIN="pip"
if [ -x "/venv/main/bin/python3" ]; then
  PYTHON_BIN="/venv/main/bin/python3"
  PIP_BIN="/venv/main/bin/pip"
fi
echo ">>> ใช้ python: $PYTHON_BIN"

# สร้างโฟลเดอร์ที่จำเป็น
mkdir -p "$MODELS_DIR/unet"
mkdir -p "$MODELS_DIR/clip"
mkdir -p "$MODELS_DIR/vae"
mkdir -p "$MODELS_DIR/pulid"
mkdir -p "$MODELS_DIR/style_models"
mkdir -p "$MODELS_DIR/clip_vision"
mkdir -p "$MODELS_DIR/insightface/models/antelopev2"
mkdir -p "$COMFY_DIR/user/default/workflows"
mkdir -p "$CUSTOM_NODES_DIR"

# ----------------------------------------------------------------------------
# ป้องกัน torch ถูก downgrade: จับ version ปัจจุบันไว้ก่อนเริ่ม แล้วเช็คซ้ำท้ายสคริปต์
# ----------------------------------------------------------------------------
TORCH_BEFORE=$("$PYTHON_BIN" -c "import torch; print(torch.__version__)" 2>/dev/null || echo "unknown")
echo ">>> torch version ก่อนเริ่ม provisioning: $TORCH_BEFORE"

# ----------------------------------------------------------------------------
# ฟังก์ชันช่วยโหลดไฟล์ + ข้ามถ้ามีอยู่แล้ว + retry + ไม่ฆ่าทั้งสคริปต์ถ้าพัง
# ----------------------------------------------------------------------------
download_if_missing() {
  local url="$1"
  local dest="$2"
  if [ -f "$dest" ] && [ -s "$dest" ]; then
    echo ">>> ข้ามไป (มีไฟล์อยู่แล้ว): $(basename "$dest")"
    return 0
  fi
  echo ">>> กำลังโหลด: $(basename "$dest")"
  if wget -q --show-progress --tries=5 --timeout=60 --waitretry=10 -O "$dest" "$url"; then
    echo ">>> เสร็จแล้ว: $dest"
  else
    echo ">>> !!! โหลดไม่สำเร็จ: $dest"
    echo "DOWNLOAD_FAILED: $dest <- $url" >> "$FAILED_LOG"
    rm -f "$dest"  # ลบไฟล์ที่โหลดค้าง/พัง ไม่ให้ไปหลอกว่ามีไฟล์แล้ว
    return 1
  fi
}

# ====================== โมเดลหลัก ======================
# ส่วนที่ 1: UNET —> FLUX Dev —> FP8 flux1-dev-fp8.safetensors
download_if_missing \
  "https://huggingface.co/Comfy-Org/flux1-dev/resolve/main/flux1-dev-fp8.safetensors" \
  "$MODELS_DIR/unet/flux1-dev-fp8.safetensors"

# ส่วนที่ 2: Text Encoder —> clip_l.safetensors , t5xxl_fp8_e4m3fn.safetensors
download_if_missing \
  "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors" \
  "$MODELS_DIR/clip/clip_l.safetensors"
download_if_missing \
  "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp8_e4m3fn.safetensors" \
  "$MODELS_DIR/clip/t5xxl_fp8_e4m3fn.safetensors"

# ส่วนที่ 3: VAE —> ae.safetensors
download_if_missing \
  "https://huggingface.co/black-forest-labs/FLUX.1-dev/resolve/main/ae.safetensors" \
  "$MODELS_DIR/vae/ae.safetensors"

# ส่วนที่ 4: PuLID for FLUX (โมเดลหลัก, ใช้กับ PulidFluxModelLoader)
download_if_missing \
  "https://huggingface.co/guozinan/PuLID/resolve/main/pulid_flux_v0.9.1.safetensors" \
  "$MODELS_DIR/pulid/pulid_flux_v0.9.1.safetensors"

# ส่วนที่ 5: FLUX Redux —> flux1-redux-dev.safetensors
download_if_missing \
  "https://huggingface.co/black-forest-labs/FLUX.1-Redux-dev/resolve/main/flux1-redux-dev.safetensors" \
  "$MODELS_DIR/style_models/flux1-redux-dev.safetensors"

# ส่วนที่ 6: SigCLIP Vision (สำหรับ Redux) —> sigclip_vision_patch14_384.safetensors
download_if_missing \
  "https://huggingface.co/Comfy-Org/sigclip_vision_384/resolve/main/sigclip_vision_patch14_384.safetensors" \
  "$MODELS_DIR/clip_vision/sigclip_vision_patch14_384.safetensors"

# ----------------------------------------------------------------------------
# ส่วนที่ 7: ติดตั้ง Custom Node ที่จำเป็น
#   *** แก้ไข: PuLID ต้องเป็น lldacing/ComfyUI_PuLID_Flux_ll (ตัว _ll เท่านั้น) ***
#   ชื่อ node class ApplyPulidFlux / PulidFluxEvaClipLoader / PulidFluxInsightFaceLoader /
#   PulidFluxModelLoader มาจาก fork นี้เท่านั้น repo อื่น (เช่น balazik) ใช้ไม่ได้
# ----------------------------------------------------------------------------
install_node() {
  local name="$1"
  local repo="$2"
  if [ -d "$CUSTOM_NODES_DIR/$name" ]; then
    echo ">>> $name มีอยู่แล้ว ข้าม"
  else
    echo ">>> กำลังติดตั้ง $name"
    if git clone "$repo" "$CUSTOM_NODES_DIR/$name"; then
      if [ -f "$CUSTOM_NODES_DIR/$name/requirements.txt" ]; then
        "$PIP_BIN" install -r "$CUSTOM_NODES_DIR/$name/requirements.txt" --break-system-packages || \
          echo "PIP_REQS_FAILED: $name" >> "$FAILED_LOG"
      fi
    else
      echo "CLONE_FAILED: $name <- $repo" >> "$FAILED_LOG"
    fi
  fi
}

# *** แก้จาก balazik/ComfyUI-PuLID-Flux เป็น lldacing/ComfyUI_PuLID_Flux_ll ***
install_node "ComfyUI_PuLID_Flux_ll" "https://github.com/lldacing/ComfyUI_PuLID_Flux_ll.git"
install_node "ComfyUI-KJNodes" "https://github.com/kijai/ComfyUI-KJNodes.git"
install_node "rgthree-comfy" "https://github.com/rgthree/rgthree-comfy.git"
# เอา ComfyUI-Impact-Pack ออก: ไม่เกี่ยวกับ workflow นี้ ตัดออกเพื่อลดเวลา+ความเสี่ยง conflict
# install_node "ComfyUI-Impact-Pack" "https://github.com/ltdrdata/ComfyUI-Impact-Pack.git"

# ----------------------------------------------------------------------------
# ส่วนที่ 7.5: dependency เฉพาะของ PuLID ที่ "ไม่ได้อยู่ใน requirements.txt ของ repo"
#   *** facenet_pytorch ต้องลงแบบ --no-deps เท่านั้น ไม่งั้น pip จะดึง torch<2.3.0
#       มาทับ torch 2.10.0+cu130 ที่ template เตรียมไว้ ทำให้ระบบพังทั้งยวง ***
# ----------------------------------------------------------------------------
echo ">>> กำลังลง PuLID extra dependencies (facenet-pytorch แบบ --no-deps)..."
"$PIP_BIN" install --no-deps facenet-pytorch --break-system-packages || \
  echo "PIP_FAILED: facenet-pytorch" >> "$FAILED_LOG"
"$PIP_BIN" install insightface onnxruntime-gpu facexlib --break-system-packages || \
  echo "PIP_FAILED: insightface/onnxruntime-gpu/facexlib" >> "$FAILED_LOG"

# ----------------------------------------------------------------------------
# ส่วนที่ 7.6: โหลดโมเดลเฉพาะของ PuLID (EVA-CLIP + antelopev2)
#   *** เดิมไม่มีส่วนนี้เลย ต้อง manual โหลดทุกครั้ง ***
# ----------------------------------------------------------------------------
echo ">>> กำลังโหลดโมเดล EVA-CLIP และ antelopev2 (insightface) สำหรับ PuLID..."
MODELS_DIR="$MODELS_DIR" "$PYTHON_BIN" - <<'PYEOF' || echo "PULID_MODEL_DOWNLOAD_FAILED" >> "$FAILED_LOG"
import os
from huggingface_hub import hf_hub_download

repo = "Comfy-Org/PuLID_flux_comfyui"
token = os.getenv("HF_TOKEN")
models_dir = os.environ["MODELS_DIR"]

pulid_dir = os.path.join(models_dir, "pulid")
antelope_dir = os.path.join(models_dir, "insightface/models/antelopev2")
os.makedirs(pulid_dir, exist_ok=True)
os.makedirs(antelope_dir, exist_ok=True)

eva_target = os.path.join(pulid_dir, "eva02_ViT_L_14_336_doc_penultimate_4.pt")
if not (os.path.exists(eva_target) and os.path.getsize(eva_target) > 0):
    print("Downloading EVA-CLIP...")
    p = hf_hub_download(repo_id=repo, filename="eva02_ViT_L_14_336_doc_penultimate_4.pt", token=token)
    os.system(f"cp '{p}' '{eva_target}'")
else:
    print("EVA-CLIP มีอยู่แล้ว ข้าม")

for f in ["1080p.onnx", "2d106det.onnx", "scrfd_10g_bnkps.onnx", "glintr100.onnx"]:
    target = os.path.join(antelope_dir, f)
    if os.path.exists(target) and os.path.getsize(target) > 0:
        print(f"{f} มีอยู่แล้ว ข้าม")
        continue
    print(f"Downloading antelopev2/{f}...")
    p = hf_hub_download(repo_id=repo, filename=f"antelopev2/{f}", token=token)
    os.system(f"cp '{p}' '{target}'")

print("PuLID extra models: done")
PYEOF

echo "============================================================"
echo "โหลดโมเดล + Custom Nodes สำหรับสร้าง Character Dataset เสร็จแล้ว"
echo "ComfyUI path: $COMFY_DIR"
echo "============================================================"

# ----------------------------------------------------------------------------
# แก้ไขปัญหา Illegal instruction จาก kornia_rs บน CPU เก่า
# ----------------------------------------------------------------------------
echo "=============================>>> กำลังแก้ไข kornia เพื่อป้องกัน Illegal instruction... ============================="
"$PIP_BIN" uninstall -y kornia kornia_rs || true
"$PIP_BIN" install --no-deps kornia==0.7.3 --break-system-packages || echo "PIP_FAILED: kornia==0.7.3" >> "$FAILED_LOG"
echo ">>> ติดตั้ง kornia==0.7.3 เสร็จแล้ว"

# ----------------------------------------------------------------------------
# ส่วนสุดท้าย: เช็ค torch version ว่าไม่ถูกใครแอบ downgrade ระหว่างทาง
# ----------------------------------------------------------------------------
TORCH_AFTER=$("$PYTHON_BIN" -c "import torch; print(torch.__version__)" 2>/dev/null || echo "unknown")
echo "============================================================"
echo ">>> torch version ก่อน provisioning : $TORCH_BEFORE"
echo ">>> torch version หลัง provisioning : $TORCH_AFTER"
if [ "$TORCH_BEFORE" != "unknown" ] && [ "$TORCH_BEFORE" != "$TORCH_AFTER" ]; then
  echo "!!! คำเตือน: torch version เปลี่ยนไประหว่าง provisioning — ตรวจสอบด่วน!"
  echo "TORCH_VERSION_CHANGED: $TORCH_BEFORE -> $TORCH_AFTER" >> "$FAILED_LOG"
fi

# ----------------------------------------------------------------------------
# สรุปไฟล์/ขั้นตอนที่ล้มเหลว (ถ้ามี) แทนการปล่อยให้เงียบแล้วไปเจอเองทีหลัง
# ----------------------------------------------------------------------------
echo "============================================================"
if [ -s "$FAILED_LOG" ]; then
  echo "!!! มีรายการที่ล้มเหลวระหว่าง provisioning ($FAILED_LOG):"
  cat "$FAILED_LOG"
else
  echo ">>> Provisioning เสร็จสมบูรณ์ ไม่มีรายการล้มเหลว"
fi
echo "============================================================"
