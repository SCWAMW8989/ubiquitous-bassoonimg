#!/usr/bin/env python3
"""guard_handler.py (Serverless Edition v1_5)

Security wrapper around the stock worker-comfyui handler (/handler.py).
start.sh is patched at build time to run this file instead of /handler.py.

The stock handler runs ANY workflow it is sent. Anyone holding a key for
this endpoint could run any node graph the image contains. This wrapper
checks every job first and only passes it on when it looks like the
Qwen-Image-Edit job the iPhone Shortcut sends.

Checks (all limits can be changed with endpoint env vars, no rebuild):
  - Only allowlisted node types           GUARD_EXTRA_NODES (comma list) adds more
  - At most GUARD_MAX_NODES nodes         default 40
  - At most GUARD_MAX_IMAGES input images default 3
  - Each image at most GUARD_MAX_IMAGE_MB default 12 (decoded size, about)
  - Image and output names: plain file names only, no folders or ".."
  - LoadImage may only read images uploaded in the same job
  - KSampler steps <= GUARD_MAX_STEPS     default 60
  - ImageScaleToTotalPixels megapixels <= GUARD_MAX_MEGAPIXELS  default 2.0
  - Any text value <= GUARD_MAX_TEXT characters                 default 4000
  - The per-request comfy_org_api_key field is removed (no paid API nodes)

GUARD_DISABLE=1 turns every check off (emergency use only).
A rejected job returns {"error": "..."} and never reaches ComfyUI.
"""

import json
import os
import re
import sys

import runpod

# Load the stock handler from / without starting it (it only starts under __main__).
sys.path.insert(0, "/")
import handler as base_handler  # noqa: E402

ALLOWED_NODES = {
    "UnetLoaderGGUF",
    "CLIPLoaderGGUF",
    "VAELoader",
    "LoadImage",
    "ImageScaleToTotalPixels",
    "ModelSamplingAuraFlow",
    "TextEncodeQwenImageEditPlus",
    "VAEEncode",
    "KSampler",
    "VAEDecode",
    "SaveImage",
}
ALLOWED_NODES |= {
    n.strip() for n in os.environ.get("GUARD_EXTRA_NODES", "").split(",") if n.strip()
}


def _int_env(name, default):
    try:
        return int(os.environ.get(name, default))
    except ValueError:
        return default


def _float_env(name, default):
    try:
        return float(os.environ.get(name, default))
    except ValueError:
        return default


MAX_NODES = _int_env("GUARD_MAX_NODES", 40)
MAX_IMAGES = _int_env("GUARD_MAX_IMAGES", 3)
MAX_IMAGE_MB = _float_env("GUARD_MAX_IMAGE_MB", 12.0)
MAX_STEPS = _int_env("GUARD_MAX_STEPS", 60)
MAX_MEGAPIXELS = _float_env("GUARD_MAX_MEGAPIXELS", 2.0)
MAX_TEXT = _int_env("GUARD_MAX_TEXT", 4000)
DISABLED = os.environ.get("GUARD_DISABLE", "0") == "1"

# Plain file name: starts with a letter or digit, then letters, digits, . _ -
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$")


def _b64_payload(value):
    """Strip a data: URI prefix, if present, and return the base64 part."""
    return value.split(",", 1)[1] if "," in value else value


def check_job(job_input):
    """Return (clean_input, None) when the job is allowed, or (None, reason)."""
    if isinstance(job_input, str):
        try:
            job_input = json.loads(job_input)
        except json.JSONDecodeError:
            return None, "Invalid JSON format in input"
    if not isinstance(job_input, dict):
        return None, "Input must be a JSON object"

    workflow = job_input.get("workflow")
    if isinstance(workflow, str):
        try:
            workflow = json.loads(workflow)
        except json.JSONDecodeError:
            return None, "Invalid JSON in 'workflow'"
    if not isinstance(workflow, dict) or not workflow:
        return None, "Missing or empty 'workflow' object"
    if len(workflow) > MAX_NODES:
        return None, f"Workflow has {len(workflow)} nodes; the limit is {MAX_NODES}"

    # ---- input images --------------------------------------------------
    images = job_input.get("images") or []
    if not isinstance(images, list):
        return None, "'images' must be a list"
    if len(images) > MAX_IMAGES:
        return None, f"Too many images ({len(images)}); the limit is {MAX_IMAGES}"
    max_b64_chars = int(MAX_IMAGE_MB * 1024 * 1024 * 4 / 3) + 4
    uploaded = set()
    for img in images:
        if not isinstance(img, dict) or "name" not in img or "image" not in img:
            return None, "Each image needs 'name' and 'image'"
        name, data = img["name"], img["image"]
        if not isinstance(name, str) or not SAFE_NAME.match(name):
            return None, f"Image name not allowed: {name!r} (plain file names only)"
        if not isinstance(data, str) or len(_b64_payload(data)) > max_b64_chars:
            return None, f"Image {name} is larger than {MAX_IMAGE_MB:g} MB"
        uploaded.add(name)

    # ---- nodes ---------------------------------------------------------
    for node_id, node in workflow.items():
        if not isinstance(node, dict):
            return None, f"Node {node_id} is not an object"
        ctype = node.get("class_type")
        if ctype not in ALLOWED_NODES:
            return None, f"Node {node_id}: type {ctype!r} is not allowed on this endpoint"
        inputs = node.get("inputs") or {}
        if not isinstance(inputs, dict):
            return None, f"Node {node_id}: 'inputs' must be an object"

        for key, val in inputs.items():
            if isinstance(val, str) and len(val) > MAX_TEXT:
                return None, f"Node {node_id}: '{key}' is longer than {MAX_TEXT} characters"

        if ctype == "LoadImage":
            ref = inputs.get("image")
            if not isinstance(ref, str) or not SAFE_NAME.match(ref):
                return None, f"Node {node_id}: LoadImage name not allowed: {ref!r}"
            if ref not in uploaded:
                return None, f"Node {node_id}: LoadImage must use an image sent in this job ({ref!r} was not)"

        if ctype == "SaveImage":
            prefix = inputs.get("filename_prefix", "ComfyUI")
            if not isinstance(prefix, str) or not SAFE_NAME.match(prefix):
                return None, f"Node {node_id}: filename_prefix not allowed: {prefix!r}"

        if ctype == "KSampler":
            steps = inputs.get("steps", 0)
            if not isinstance(steps, (int, float)) or steps > MAX_STEPS:
                return None, f"Node {node_id}: steps must be a number <= {MAX_STEPS}"

        if ctype == "ImageScaleToTotalPixels":
            mp = inputs.get("megapixels", 0)
            if not isinstance(mp, (int, float)) or mp > MAX_MEGAPIXELS:
                return None, f"Node {node_id}: megapixels must be a number <= {MAX_MEGAPIXELS:g}"

    clean = {"workflow": workflow}
    if images:
        clean["images"] = images
    # comfy_org_api_key is deliberately dropped.
    return clean, None


def guarded_handler(job):
    if DISABLED:
        return base_handler.handler(job)
    clean, reason = check_job(job.get("input"))
    if reason:
        print(f"guard_handler - rejected job {job.get('id')}: {reason}")
        return {"error": f"Rejected by endpoint guard: {reason}"}
    job = dict(job)
    job["input"] = clean
    return base_handler.handler(job)


if __name__ == "__main__":
    state = "DISABLED (GUARD_DISABLE=1)" if DISABLED else "on"
    print(f"guard_handler - starting, checks {state}; nodes allowed: {sorted(ALLOWED_NODES)}")
    runpod.serverless.start({"handler": guarded_handler})
