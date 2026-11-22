"""Build the original Nexus AR Catalyst 2960 inspection asset with Blender.

blender -b --factory-startup --python-exit-code 1 --python build_catalyst2960.py -- switch-2960-v1.usdz
"""

from collections import defaultdict
from math import cos, pi, sin
from pathlib import Path
import sys

import bpy


WIDTH, HEIGHT, DEPTH = 0.445, 0.044, 0.236
FRONT, REAR = -DEPTH / 2, DEPTH / 2
PALETTE = {
    "graphite": ((0.063, 0.080, 0.091), 0.43, 0.48),
    "fascia": ((0.027, 0.225, 0.300), 0.28, 0.44),
    "metal": ((0.35, 0.43, 0.47), 0.65, 0.33),
    "rim": ((0.12, 0.17, 0.19), 0.5, 0.32),
    "recess": ((0.011, 0.016, 0.020), 0.05, 0.77),
    "contacts": ((0.70, 0.43, 0.15), 0.75, 0.32),
    "markings": ((0.79, 0.86, 0.87), 0.0, 0.64),
    "lens": ((0.24, 0.42, 0.37), 0.0, 0.38),
    "console": ((0.052, 0.40, 0.63), 0.0, 0.56),
}


def blender_point(x, y, z):
    # Nexus uses Y-up and a front face on -Z. USD export maps Blender Z to Y.
    return x, -z, y


geometry = defaultdict(lambda: ([], []))


def shape(material, points, faces):
    vertices, polygons = geometry[material]
    start = len(vertices)
    vertices.extend(blender_point(*point) for point in points)
    polygons.extend(tuple(start + i for i in face) for face in faces)


def box(material, center, size):
    x, y, z = center
    w, h, d = (side / 2 for side in size)
    corners = [
        (x - w, y - h, z - d), (x + w, y - h, z - d),
        (x + w, y + h, z - d), (x - w, y + h, z - d),
        (x - w, y - h, z + d), (x + w, y - h, z + d),
        (x + w, y + h, z + d), (x - w, y + h, z + d),
    ]
    shape(material, corners, [(3, 2, 1, 0), (4, 5, 6, 7), (0, 1, 5, 4),
                            (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)])


def cylinder(material, center, radius, depth, axis="z"):
    x, y, z = center
    steps = 12
    points = []
    for end in (-depth / 2, depth / 2):
        for step in range(steps):
            angle = 2 * pi * step / steps
            u, v = cos(angle) * radius, sin(angle) * radius
            points.append((x + u, y + v, z + end) if axis == "z" else (x + v, y + end, z + u))
    faces = [(step, (step + 1) % steps, (step + 1) % steps + steps, step + steps)
             for step in range(steps)]
    shape(material, points, [tuple(reversed(range(steps))), tuple(range(steps, steps * 2)), *faces])


def frame(material, center, width, height, rail, depth):
    x, y, z = center
    for sign in (-1, 1):
        box(material, (x, y + sign * (height - rail) / 2, z), (width, rail, depth))
        box(material, (x + sign * (width - rail) / 2, y, z), (rail, height - 2 * rail, depth))


def jack(x, y, z, facing, surround="metal", pins=True):
    frame(surround, (x, y, z), 0.0164, 0.0131, 0.00125, 0.003)
    frame("rim", (x, y, z - facing * 0.0015), 0.0141, 0.0108, 0.0007, 0.002)
    box("recess", (x, y, z - facing * 0.0023), (0.014, 0.011, 0.0006))
    box("recess", (x, y - 0.0045, z + facing * 0.0002), (0.006, 0.0017, 0.0012))
    if pins:
        for pin in range(8):
            box("contacts", (x + (pin - 3.5) * 0.00112, y + 0.0022, z - facing * 0.001),
                (0.00050, 0.0027, 0.00038))


def label(text, x, y, z, size, rear=False):
    glyphs = bpy.data.curves.new("Legend", "FONT")
    glyphs.body, glyphs.size, glyphs.resolution_u = text, size, 3
    glyphs.align_x, glyphs.align_y = "CENTER", "CENTER"
    obj = bpy.data.objects.new("Legend", glyphs)
    bpy.context.collection.objects.link(obj)
    obj.parent = root
    obj.location = blender_point(x, y, z)
    obj.rotation_euler = (pi / 2, 0, 0 if rear else pi)
    obj.data.materials.append(materials["markings"])
    labels.append(obj)


def port_center(index):
    # Keep this contract aligned with LabScenePort.networkPanel. USD markers
    # are compared with the actual Swift port positions when the app loads it.
    if index < 24:
        return WIDTH / 2 - 0.061 - (index // 2) * 0.021 - (index // 12) * 0.012, (0.009 if index % 2 == 0 else -0.009)
    return -WIDTH / 2 + 0.061 - (index - 24) * 0.024, 0.0


def make_chassis():
    box("graphite", (0, 0, 0), (WIDTH - 0.001, HEIGHT - 0.002, DEPTH - 0.009))
    box("rim", (0, HEIGHT / 2 - 0.0006, 0.002), (WIDTH - 0.003, 0.0012, DEPTH - 0.008))
    box("graphite", (0, -HEIGHT / 2 + 0.0006, 0.002), (WIDTH - 0.003, 0.0012, DEPTH - 0.008))
    box("fascia", (0, 0, FRONT - 0.0003), (WIDTH - 0.002, HEIGHT - 0.0022, 0.002))
    box("metal", (0, 0, REAR - 0.0005), (WIDTH - 0.003, HEIGHT - 0.003, 0.002))
    for edge in (-1, 1):
        rail = edge * (WIDTH / 2 - 0.002)
        box("rim", (rail, 0, 0), (0.004, HEIGHT - 0.002, DEPTH - 0.007))
        for row in range(3):
            for index in range(22):
                box("recess", (edge * WIDTH / 2, 0.008 - row * 0.008, -0.057 + index * 0.0055),
                    (0.0007, 0.0035, 0.0025))
        for dz in (-0.090, 0.079):
            cylinder("metal", (edge * 0.204, HEIGHT / 2, dz), 0.0026, 0.00085, axis="y")
            box("recess", (edge * 0.204, HEIGHT / 2 + 0.0005, dz), (0.0031, 0.00025, 0.0006))
        for dz in (-0.098, 0.100):
            box("graphite", (edge * 0.184, -HEIGHT / 2 + 0.0002, dz), (0.013, 0.0012, 0.013))


def make_front():
    for group in range(2):
        center = 0.109 - group * 0.138
        box("rim", (center, 0, FRONT - 0.0018), (0.127, 0.034, 0.0025))
    box("rim", (-0.173, 0, FRONT - 0.0018), (0.050, 0.032, 0.0025))
    for index in range(26):
        x, y = port_center(index)
        jack(x, y, FRONT - 0.004, -1)
        status_y = y + (0.0082 if index % 2 == 0 or index >= 24 else -0.0082)
        if index < 24:
            lab_x = x - 0.0020
            box("lens", (x + 0.0053, status_y, FRONT - 0.0032), (0.0026, 0.00145, 0.00075))
        else:
            lab_x = x
        label(str(index + 1) if index < 24 else f"G{index - 23}", lab_x, status_y, FRONT - 0.0037, 0.0036)
        marker = bpy.data.objects.new(f"Port_{index + 1:02}", None)
        bpy.context.collection.objects.link(marker)
        marker.parent = root
        marker.location = blender_point(x, y, FRONT - 0.004)
    box("recess", (0.194, 0, FRONT - 0.0024), (0.032, 0.036, 0.002))
    for index, name in enumerate(("SYST", "RPS", "STAT", "DPLX")):
        y = -0.009 + index * 0.005
        # The SYST lens is rendered by Nexus AR on both model variants.
        if index:
            box("lens", (0.2005, y, FRONT - 0.0059), (0.003, 0.002, 0.001))
        label(name, 0.190, y, FRONT - 0.0037, 0.0035)
    cylinder("metal", (0.186, -0.015, FRONT - 0.004), 0.0026, 0.002)
    label("MODE", 0.199, -0.015, FRONT - 0.0037, 0.0032)
    label("CATALYST 2960", 0.191, 0.016, FRONT - 0.0037, 0.0031)
    label("10/100/1000", -0.173, 0.012, FRONT - 0.0037, 0.0034)


def make_rear():
    box("rim", (0.156, 0, REAR + 0.0015), (0.036, 0.027, 0.003))
    frame("graphite", (0.156, 0, REAR + 0.004), 0.027, 0.019, 0.0024, 0.004)
    box("recess", (0.156, 0, REAR + 0.002), (0.024, 0.016, 0.002))
    for dx, y in ((-0.006, -0.003), (0, 0.003), (0.006, -0.003)):
        box("contacts", (0.156 + dx, y, REAR + 0.003), (0.0015, 0.0035, 0.002))
    jack(0.112, 0, REAR + 0.0025, 1, surround="console")
    frame("rim", (-0.135, 0, REAR + 0.0025), 0.062, 0.023, 0.0025, 0.004)
    for column in range(12):
        box("recess", (-0.1625 + column * 0.005, 0, REAR + 0.0015), (0.0028, 0.017, 0.002))
    box("recess", (-0.045, 0, REAR + 0.002), (0.040, 0.020, 0.003))
    frame("rim", (-0.045, 0, REAR + 0.003), 0.040, 0.022, 0.0025, 0.003)
    for col in range(7):
        for y in (-0.004, 0.004):
            box("contacts", (-0.058 + col * 0.0043, y, REAR + 0.003), (0.0011, 0.002, 0.001))
    for text, x in (("AC IN", 0.156), ("CONSOLE", 0.112), ("RPS", -0.045), ("FAN", -0.135)):
        label(text, x, -0.0155, REAR + 0.001, 0.0039, rear=True)
    for x in (-0.205, 0.205):
        for y in (-0.0125, 0.0125):
            cylinder("rim", (x, y, REAR + 0.0015), 0.0031, 0.0015)
            box("metal", (x, y, REAR + 0.0023), (0.0034, 0.0007, 0.0004))


bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.context.scene.unit_settings.system = "METRIC"
root = bpy.data.objects.new("Catalyst_2960_24TT_L", None)
bpy.context.collection.objects.link(root)
materials = {}
labels = []
for name, (rgb, metallic, roughness) in PALETTE.items():
    material = bpy.data.materials.new(name)
    if not material.node_tree:
        material.use_nodes = True
    principled = material.node_tree.nodes.get("Principled BSDF")
    principled.inputs["Base Color"].default_value = (*rgb, 1)
    principled.inputs["Metallic"].default_value = metallic
    principled.inputs["Roughness"].default_value = roughness
    material.diffuse_color = (*rgb, 1)
    materials[name] = material

make_chassis()
make_front()
make_rear()
for name, (vertices, faces) in geometry.items():
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    mesh.materials.append(materials[name])
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    obj.parent = root

# Join all legends so the detailed asset has one mesh per material.
bpy.ops.object.select_all(action="DESELECT")
for obj in labels:
    obj.select_set(True)
bpy.context.view_layer.objects.active = labels[0]
bpy.ops.object.convert(target="MESH")
bpy.ops.object.join()
bpy.context.object.name = "panel_legends"

output = Path(sys.argv[sys.argv.index("--") + 1]).resolve()
output.parent.mkdir(parents=True, exist_ok=True)
bpy.ops.wm.usd_export(filepath=str(output), export_animation=False, export_cameras=False, export_lights=False,
                      convert_world_material=False, convert_orientation=True, export_global_up_selection="Y",
                      export_global_forward_selection="NEGATIVE_Z")
if not output.is_file() or output.stat().st_size > 2_000_000:
    raise RuntimeError("Missing USDZ or inspection asset exceeds 2 MB.")
