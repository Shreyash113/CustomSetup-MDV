variable "TAG" {
  default = "cu128"
}

# -------------------------------------------------
# Common settings
# -------------------------------------------------
target "common" {
  context = "."
  platforms = ["linux/amd64"]
  args = {
    BUILDKIT_INLINE_CACHE = "1"
  }
}

# -------------------------------------------------
# Main production image
# CUDA 12.8 + Python 3.12
# -------------------------------------------------
target "comfyui_wan_ltx" {
  inherits = ["common"]
  dockerfile = "Dockerfile"
  tags = [
    "yourname/comfyui-wan-ltx:${TAG}",
    "yourname/comfyui-wan-ltx:latest"
  ]
}

# -------------------------------------------------
# Local development build (no push)
# -------------------------------------------------
target "dev" {
  inherits = ["common"]
  dockerfile = "Dockerfile"
  tags = ["yourname/comfyui-wan-ltx:dev"]
  output = ["type=docker"]
}