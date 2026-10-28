"""Depth Anything V2 Small (Apache-2.0, depth-anything/Depth-Anything-V2-Small-hf) as a Core ML model the
iPad app runs on the Neural Engine of iPadOS 15: relative inverse depth (near = high) of a 518 × 518
picture. The conversion targets iOS 15, so it fails here (in CI) rather than on the iPad when an
operation needs a newer system. 518 is the size the model was trained at: its position embeddings
need no (bicubic) interpolation.

    python tools/convert_depth.py ios/App/Models/DepthAnything.mlpackage
"""
import sys

import coremltools as ct
import torch
from transformers import AutoModelForDepthEstimation

OUT = sys.argv[1]
SIZE = 518


class Depth(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, x):
        y = self.m(pixel_values=x)
        d = y[0] if isinstance(y, (tuple, list)) else y.predicted_depth
        return d.reshape(1, 1, SIZE, SIZE)


model = AutoModelForDepthEstimation.from_pretrained("depth-anything/Depth-Anything-V2-Small-hf", torchscript=True).eval()
x = torch.rand(1, 3, SIZE, SIZE)
with torch.no_grad():
    traced = torch.jit.trace(Depth(model), x, strict=False)

# ImageNet normalisation in the input: (pixel / 255 - mean) / std, one std for the three channels
mean = [0.485, 0.456, 0.406]
std = 0.226
ml = ct.convert(
    traced,
    inputs=[ct.ImageType(name="image", shape=x.shape, scale=1 / (255 * std), bias=[-m / std for m in mean], color_layout=ct.colorlayout.RGB)],
    outputs=[ct.TensorType(name="depth")],
    minimum_deployment_target=ct.target.iOS15,
    compute_precision=ct.precision.FLOAT16,
    convert_to="mlprogram",
)
ml.short_description = "Depth Anything V2 Small (Apache-2.0): relative inverse depth, near = high"
ml.save(OUT)
print("saved", OUT)
