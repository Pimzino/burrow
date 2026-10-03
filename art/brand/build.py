# Burrow brand pack. Renders the 3D "arch" icon in Cycles and composes every brand asset with numpy.
#
#   Blender -b --factory-startup -P build.py -- <outdir>        (see build.sh)
#
# Environment:
#   BRAND_SAMPLES   Cycles samples for the icon renders (default 384)
#   BRAND_REUSE=1   reuse the cached renders in .work/ and only recompose (fast iteration)
import bpy, math, os, sys, subprocess, zlib
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from lib import *  # noqa: E402,F401,F403

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = os.path.abspath(argv[0] if argv else os.path.join(HERE, "out"))
WORK = os.path.join(HERE, ".work")
os.makedirs(OUT, exist_ok=True)
os.makedirs(WORK, exist_ok=True)
SAMPLES = int(os.environ.get("BRAND_SAMPLES", "384"))
REUSE = os.environ.get("BRAND_REUSE") == "1"

# ---------------------------------------------------------------- icon grid (macOS 26)
CANVAS, BODY = 1024, 824
# Where the arch sits in the 1024 canvas: crown top and feet (pixels). 527 px = 64% of the body.
ARCH_TOP, ARCH_FEET = 228, 740
UNIT = (ARCH_FEET - ARCH_TOP) / (MARK["Ro"] + MARK["leg"])   # pixels per scene unit at the wall plane

# ---------------------------------------------------------------- scene look
ARCH_COLOR = hx("6E5878")        # dusky plum-violet ceramic (velvet family, lifted so it reads)
ARCH_DEPTH = 0.30
ARCH_ROUND = 0.10
TUN_L = 0.42                     # tunnel depth behind the wall
TUN_W = 0.07                     # tunnel is this much wider than the opening, so its side walls hide behind the legs
ORB_Y = 0.16                     # orb depth behind the wall plane
ORB_EM = 7.0                     # orb emission strength
ORB_LIMB = 0.5                   # orb rim brightness relative to its centre (soft limb)
HALO_R = 2.2                     # glow shell radius (x orb radius)
HALO_P = 3.0                     # how fast the shell's glow falls off towards its edge
HALO_EM = 1.0
CORE_W = 7.0                     # watts of the light inside the orb
CAM_ELEV = 7.0                   # degrees
CAM_LENS = 85.0
FLOOR_FADE = 1.25              # how far in front of the wall the floor polish reaches

def read_img(path):
    im = bpy.data.images.load(path, check_existing=False)
    im.colorspace_settings.name = "Non-Color"
    w, h = im.size
    px = np.empty(w * h * 4, np.float32)
    im.pixels.foreach_get(px)
    bpy.data.images.remove(im)
    return px.reshape(h, w, 4)[::-1].copy()

# ---------------------------------------------------------------- Blender helpers
def setup_render(res_x, res_y, samples, transparent=False):
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    prefs = bpy.context.preferences.addons["cycles"].preferences
    prefs.compute_device_type = "METAL"
    prefs.get_devices()
    for d in prefs.devices:
        d.use = d.type == "METAL"
    sc.cycles.device = "GPU"
    sc.cycles.samples = samples
    sc.cycles.use_adaptive_sampling = True
    sc.cycles.use_denoising = True
    sc.cycles.denoiser = "OPENIMAGEDENOISE"
    sc.cycles.max_bounces = 8
    sc.cycles.seed = 3
    sc.render.resolution_x, sc.render.resolution_y = res_x, res_y
    sc.render.resolution_percentage = 100
    sc.render.film_transparent = transparent
    sc.render.image_settings.file_format = "PNG"
    sc.render.image_settings.color_mode = "RGBA"
    sc.render.image_settings.color_depth = "16"
    sc.view_settings.view_transform = "AgX"
    sc.view_settings.look = "AgX - Punchy"
    sc.view_settings.exposure = 0.0
    return sc

def clear_scene():
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o, do_unlink=True)
    for coll in (bpy.data.meshes, bpy.data.curves, bpy.data.materials, bpy.data.lights, bpy.data.cameras):
        for b in list(coll):
            coll.remove(b)

def new_mat(name):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    return m, m.node_tree

def ramp_node(nt, stops):
    r = nt.nodes.new("ShaderNodeValToRGB")
    cr = r.color_ramp
    cr.elements[0].position, cr.elements[0].color = stops[0][0], (*stops[0][1], 1)
    cr.elements[1].position, cr.elements[1].color = stops[-1][0], (*stops[-1][1], 1)
    for p, c in stops[1:-1]:
        e = cr.elements.new(p)
        e.color = (*c, 1)
    return r

def mat_ceramic():
    m, nt = new_mat("ceramic")
    b = nt.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*lin(ARCH_COLOR), 1)
    b.inputs["Roughness"].default_value = 0.40
    b.inputs["Coat Weight"].default_value = 1.0
    b.inputs["Coat Roughness"].default_value = 0.07
    b.inputs["Subsurface Weight"].default_value = 0.15
    b.inputs["Subsurface Radius"].default_value = (0.35, 0.15, 0.3)
    b.inputs["Subsurface Scale"].default_value = 0.03
    return m

def mat_wall():
    """Matte earth wall with a built-in night-soil -> burrow gradient (lighter at the top) so the
    icon edge reads on a dark Dock; still receives the light spill from the arch."""
    m, nt = new_mat("wall")
    b = nt.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*lin(BURROW) * 1.4, 1)
    b.inputs["Roughness"].default_value = 0.9
    geo = nt.nodes.new("ShaderNodeNewGeometry")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    mr = nt.nodes.new("ShaderNodeMapRange")
    mr.inputs["From Min"].default_value = -0.6
    mr.inputs["From Max"].default_value = 1.35
    rp = ramp_node(nt, [(0.0, lin(NIGHT)), (0.55, lin(NIGHT * 0.5 + BURROW * 0.5)), (1.0, lin(BURROW * 1.15 + VELVET * 0.15))])
    nt.links.new(geo.outputs["Position"], sep.inputs[0])
    nt.links.new(sep.outputs["Z"], mr.inputs["Value"])
    nt.links.new(mr.outputs["Result"], rp.inputs["Fac"])
    nt.links.new(rp.outputs["Color"], b.inputs["Emission Color"])
    b.inputs["Emission Strength"].default_value = WALL_EM
    return m

WALL_EM = 1.35

def mat_floor():
    """Dark polished floor. Ambient occlusion darkens it (and kills the reflection) where the
    arch feet stand, so the arch is planted with a contact shadow."""
    m, nt = new_mat("floor")
    b = nt.nodes["Principled BSDF"]
    ao = nt.nodes.new("ShaderNodeAmbientOcclusion")
    ao.inputs["Distance"].default_value = 0.30
    ao.samples = 16
    pw0 = nt.nodes.new("ShaderNodeMath"); pw0.operation = "POWER"; pw0.inputs[1].default_value = 3.0
    nt.links.new(ao.outputs["AO"], pw0.inputs[0])
    # a second, tight occlusion term: a crisp contact shadow right where the legs meet the floor
    ao2 = nt.nodes.new("ShaderNodeAmbientOcclusion")
    ao2.inputs["Distance"].default_value = 0.07
    ao2.samples = 16
    pw2 = nt.nodes.new("ShaderNodeMath"); pw2.operation = "POWER"; pw2.inputs[1].default_value = 2.5
    nt.links.new(ao2.outputs["AO"], pw2.inputs[0])
    pw = nt.nodes.new("ShaderNodeMath"); pw.operation = "MULTIPLY"
    nt.links.new(pw0.outputs[0], pw.inputs[0])
    nt.links.new(pw2.outputs[0], pw.inputs[1])
    col = nt.nodes.new("ShaderNodeMix"); col.data_type = "RGBA"
    col.inputs[6].default_value = (0, 0, 0, 1)
    col.inputs[7].default_value = (*lin(BURROW) * 0.9, 1)
    nt.links.new(pw.outputs[0], col.inputs[0])
    nt.links.new(col.outputs[2], b.inputs["Base Color"])
    # the polish fades out towards the viewer, keeping the reflection short
    geo = nt.nodes.new("ShaderNodeNewGeometry")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    fade = nt.nodes.new("ShaderNodeMapRange")
    fade.inputs["From Min"].default_value = -FLOOR_FADE
    fade.inputs["From Max"].default_value = -0.05
    fade.inputs["To Min"].default_value = 0.0
    fade.inputs["To Max"].default_value = 0.7
    nt.links.new(geo.outputs["Position"], sep.inputs[0])
    nt.links.new(sep.outputs["Y"], fade.inputs["Value"])
    cw = nt.nodes.new("ShaderNodeMath"); cw.operation = "MULTIPLY"
    nt.links.new(pw.outputs[0], cw.inputs[0])
    nt.links.new(fade.outputs["Result"], cw.inputs[1])
    nt.links.new(cw.outputs[0], b.inputs["Coat Weight"])
    b.inputs["Roughness"].default_value = 0.55
    b.inputs["Specular IOR Level"].default_value = 0.3
    b.inputs["Coat Roughness"].default_value = 0.30
    # Inside the tunnel the same surface turns into a warm floor lit by the orb. One continuous surface
    # (no second plane), so there is no seam or step at the threshold: the warm floor fades into the
    # polish from the wall plane forward and the light spills straight out.
    warm = nt.nodes.new("ShaderNodeBsdfPrincipled")
    warm.inputs["Base Color"].default_value = (*lin(INTERIOR) * 0.75, 1)
    warm.inputs["Roughness"].default_value = 0.30
    warm.inputs["Emission Color"].default_value = (*lin(EMBER * 0.7 + LANTERN * 0.3), 1)
    # self-glow rises towards the back so the floor meets the glowing back wall without a crease
    back_ramp = nt.nodes.new("ShaderNodeMapRange")
    back_ramp.interpolation_type = "SMOOTHSTEP"
    back_ramp.inputs["From Min"].default_value = 0.05
    back_ramp.inputs["From Max"].default_value = TUN_L
    back_ramp.inputs["To Min"].default_value = TFLOOR_EM
    back_ramp.inputs["To Max"].default_value = TFLOOR_BACK
    nt.links.new(sep.outputs["Y"], back_ramp.inputs["Value"])
    nt.links.new(back_ramp.outputs["Result"], warm.inputs["Emission Strength"])
    depth = nt.nodes.new("ShaderNodeMapRange")
    depth.interpolation_type = "SMOOTHERSTEP"
    depth.inputs["From Min"].default_value = -ARCH_DEPTH * 0.6
    depth.inputs["From Max"].default_value = 0.12
    nt.links.new(sep.outputs["Y"], depth.inputs["Value"])
    ax = nt.nodes.new("ShaderNodeMath"); ax.operation = "ABSOLUTE"
    nt.links.new(sep.outputs["X"], ax.inputs[0])
    side = nt.nodes.new("ShaderNodeMapRange")
    side.interpolation_type = "SMOOTHSTEP"
    side.inputs["From Min"].default_value = MARK["Ri"] + TUN_W + 0.03   # the fade is hidden under the legs
    side.inputs["From Max"].default_value = MARK["Ri"] + 0.04
    nt.links.new(ax.outputs[0], side.inputs["Value"])
    fac = nt.nodes.new("ShaderNodeMath"); fac.operation = "MULTIPLY"
    nt.links.new(depth.outputs["Result"], fac.inputs[0])
    nt.links.new(side.outputs["Result"], fac.inputs[1])
    mix = nt.nodes.new("ShaderNodeMixShader")
    nt.links.new(fac.outputs[0], mix.inputs[0])
    nt.links.new(b.outputs[0], mix.inputs[1])
    nt.links.new(warm.outputs[0], mix.inputs[2])
    nt.links.new(mix.outputs[0], nt.nodes["Material Output"].inputs[0])
    return m

INTERIOR = EMBER * 0.30 + LANTERN * 0.70   # albedo of the lit tunnel (the orb's light does the shading)
BACK_EM = (0.12, 2.4)                       # back wall glow: (rim strength, extra at the core)
BACK_REACH = 0.55                           # back wall glow radius (scene units)
TFLOOR_EM = 0.03                            # warm floor self-glow inside the tunnel ...
TFLOOR_BACK = 0.50                          # ... rising to this where it meets the back wall

def mat_tunnel():
    """Tunnel sides and roof (hidden behind the arch, but they bounce warm light into the opening)."""
    m, nt = new_mat("tunnel")
    b = nt.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*lin(INTERIOR) * 0.8, 1)
    b.inputs["Roughness"].default_value = 0.7
    b.inputs["Emission Color"].default_value = (*lin(EMBER), 1)
    b.inputs["Emission Strength"].default_value = 0.4
    return m

def mat_backglow(reach):
    """Tunnel end, lit by the orb, plus a radial glow centred on it: lantern near, ember at the rim."""
    m, nt = new_mat("back")
    b = nt.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*lin(INTERIOR) * 0.8, 1)
    b.inputs["Roughness"].default_value = 0.8
    tc = nt.nodes.new("ShaderNodeTexCoord")
    ln = nt.nodes.new("ShaderNodeVectorMath"); ln.operation = "LENGTH"
    mr = nt.nodes.new("ShaderNodeMapRange")
    mr.inputs["From Min"].default_value = 0.0
    mr.inputs["From Max"].default_value = reach
    mr.inputs["To Min"].default_value = 1.0
    mr.inputs["To Max"].default_value = 0.0
    rp = ramp_node(nt, [(0.0, lin(EMBER)), (0.30, lin(EMBER * 0.35 + LANTERN * 0.65)), (0.70, lin(LANTERN)), (1.0, lin(LANTERN * 0.5 + CREAM * 0.5))])
    pw = nt.nodes.new("ShaderNodeMath"); pw.operation = "POWER"; pw.inputs[1].default_value = 2.0
    mul = nt.nodes.new("ShaderNodeMath"); mul.operation = "MULTIPLY_ADD"
    mul.inputs[1].default_value = BACK_EM[1]; mul.inputs[2].default_value = BACK_EM[0]
    nt.links.new(tc.outputs["Object"], ln.inputs[0])
    nt.links.new(ln.outputs["Value"], mr.inputs["Value"])
    nt.links.new(mr.outputs["Result"], rp.inputs["Fac"])
    nt.links.new(mr.outputs["Result"], pw.inputs[0])
    nt.links.new(pw.outputs[0], mul.inputs[0])
    nt.links.new(rp.outputs["Color"], b.inputs["Emission Color"])
    nt.links.new(mul.outputs[0], b.inputs["Emission Strength"])
    return m

def mat_halo():
    m, nt = new_mat("halo")
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    tr = nt.nodes.new("ShaderNodeBsdfTransparent")
    em = nt.nodes.new("ShaderNodeEmission")
    add = nt.nodes.new("ShaderNodeAddShader")
    lw = nt.nodes.new("ShaderNodeLayerWeight")
    lw.inputs["Blend"].default_value = 0.5
    inv = nt.nodes.new("ShaderNodeMath"); inv.operation = "SUBTRACT"; inv.inputs[0].default_value = 1.0
    pw = nt.nodes.new("ShaderNodeMath"); pw.operation = "POWER"; pw.inputs[1].default_value = HALO_P
    mul = nt.nodes.new("ShaderNodeMath"); mul.operation = "MULTIPLY"; mul.inputs[1].default_value = HALO_EM
    rp = ramp_node(nt, [(0.0, lin(EMBER * 0.4 + LANTERN * 0.6)), (0.5, lin(LANTERN)), (1.0, lin(LANTERN * 0.4 + CREAM * 0.6))])
    nt.links.new(lw.outputs["Facing"], inv.inputs[1])
    nt.links.new(inv.outputs[0], pw.inputs[0])
    nt.links.new(pw.outputs[0], mul.inputs[0])
    nt.links.new(inv.outputs[0], rp.inputs["Fac"])
    nt.links.new(rp.outputs["Color"], em.inputs["Color"])
    nt.links.new(mul.outputs[0], em.inputs["Strength"])
    nt.links.new(tr.outputs[0], add.inputs[0])
    nt.links.new(em.outputs[0], add.inputs[1])
    nt.links.new(add.outputs[0], out.inputs[0])
    return m

def mat_orb():
    """The lantern orb: cream-hot where it faces the camera, lantern then ember towards its rim."""
    m, nt = new_mat("orb")
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    em = nt.nodes.new("ShaderNodeEmission")
    lw = nt.nodes.new("ShaderNodeLayerWeight")
    lw.inputs["Blend"].default_value = 0.5
    rp = ramp_node(nt, [(0.0, lin(CREAM)), (0.45, lin(CREAM * 0.55 + LANTERN * 0.45)), (0.8, lin(LANTERN)), (1.0, lin(LANTERN * 0.5 + EMBER * 0.5))])
    st = nt.nodes.new("ShaderNodeMapRange")
    st.inputs["To Min"].default_value = ORB_EM
    st.inputs["To Max"].default_value = ORB_EM * ORB_LIMB
    nt.links.new(lw.outputs["Facing"], rp.inputs["Fac"])
    nt.links.new(lw.outputs["Facing"], st.inputs["Value"])
    nt.links.new(rp.outputs["Color"], em.inputs["Color"])
    nt.links.new(st.outputs["Result"], em.inputs["Strength"])
    nt.links.new(em.outputs[0], out.inputs[0])
    return m

def door_path(r, spring, base, n=128):
    """Closed doorway outline in scene units (y up): right leg up, half circle, left leg down."""
    pts = [(r, base)]
    for i in range(n + 1):
        a = math.pi * i / n
        pts.append((r * math.cos(a), spring + r * math.sin(a)))
    pts.append((-r, base))
    return pts

def curve_from_paths(name, paths, extrude=0.0, fill="BOTH"):
    cu = bpy.data.curves.new(name, "CURVE")
    cu.dimensions = "2D"
    cu.fill_mode = fill
    cu.extrude = extrude
    for pts in paths:
        sp = cu.splines.new("POLY")
        sp.points.add(len(pts) - 1)
        for p, (x, y) in zip(sp.points, pts):
            p.co = (x, y, 0, 1)
        sp.use_cyclic_u = True
    ob = bpy.data.objects.new(name, cu)
    bpy.context.collection.objects.link(ob)
    return ob

def rounded_rect(hw, hh, r, n=16):
    pts = []
    for cx, cy, a0 in ((hw - r, hh - r, 0), (-hw + r, hh - r, 90), (-hw + r, -hh + r, 180), (hw - r, -hh + r, 270)):
        for i in range(n + 1):
            a = math.radians(a0 + 90 * i / n)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts

def sweep_arch(Ro, Ri, base, depth, rnd):
    """Rounded-rectangle section swept along the arch centre line: soft, even edges all round."""
    rc = (Ro + Ri) / 2
    prof = curve_from_paths("arch_profile", [rounded_rect((Ro - Ri) / 2, depth / 2, rnd)], fill="NONE")
    prof.hide_render = True
    cu = bpy.data.curves.new("arch_path", "CURVE")
    cu.dimensions = "2D"
    cu.bevel_mode = "OBJECT"
    cu.bevel_object = prof
    cu.use_fill_caps = True
    sp = cu.splines.new("POLY")
    pts = [(-rc, base + (0 - base) * k / 10) for k in range(10)]
    pts += [(rc * math.cos(math.pi - math.pi * i / 160), rc * math.sin(math.pi - math.pi * i / 160)) for i in range(161)]
    pts += [(rc, base * k / 10) for k in range(1, 11)]
    sp.points.add(len(pts) - 1)
    for p, (x, y) in zip(sp.points, pts):
        p.co = (x, y, 0, 1)
    ob = bpy.data.objects.new("arch", cu)
    bpy.context.collection.objects.link(ob)
    return ob

def to_mesh(ob):
    bpy.context.view_layer.objects.active = ob
    for o in bpy.context.view_layer.objects:
        o.select_set(o == ob)
    bpy.ops.object.convert(target="MESH")
    ob = bpy.context.view_layer.objects.active
    for p in ob.data.polygons:
        p.use_smooth = True
    return ob

def add_light(name, typ, loc, color, energy, size=0.1, rot=None, glossy=True, size_y=None, shadow=True):
    ld = bpy.data.lights.new(name, typ)
    ld.use_shadow = shadow
    ld.color = tuple(lin(color))
    ld.energy = energy
    if typ in ("POINT", "SPOT"):
        ld.shadow_soft_size = size
    if typ == "AREA":
        if size_y:
            ld.shape = "RECTANGLE"
            ld.size, ld.size_y = size, size_y
        else:
            ld.size = size
    o = bpy.data.objects.new(name, ld)
    o.location = loc
    o.visible_camera = False
    o.visible_glossy = glossy
    if rot:
        o.rotation_euler = rot
    bpy.context.collection.objects.link(o)
    return o

def build_icon_scene():
    """Scene units: the wall is the plane y=0, the floor z=base, the arch spring at z=0."""
    clear_scene()
    sc = setup_render(CANVAS, CANVAS, SAMPLES)
    w = bpy.data.worlds[0] if bpy.data.worlds else bpy.data.worlds.new("w")
    sc.world = w
    w.use_nodes = True
    w.node_tree.nodes["Background"].inputs["Color"].default_value = (*lin(NIGHT) * 0.25, 1)

    Ro, Ri, leg = MARK["Ro"], MARK["Ri"], MARK["leg"]
    base = -leg
    sink = 0.40   # legs continue under the floor, so the feet are cut square by the floor plane
    objs = {}

    arch = sweep_arch(Ro, Ri, base - sink, ARCH_DEPTH, ARCH_ROUND)
    arch.rotation_euler = (math.radians(90), 0, 0)
    arch.location = (0, -ARCH_DEPTH / 2, 0)
    arch = to_mesh(arch)
    arch.data.materials.append(mat_ceramic())
    objs["arch"] = arch

    R = 8.0
    wall = curve_from_paths("wall", [[(-R, base - 0.6), (R, base - 0.6), (R, R), (-R, R)],
                                     door_path(Ri + TUN_W - 0.004, 0, base - 0.3)[::-1]])
    wall.rotation_euler = (math.radians(90), 0, 0)
    wall = to_mesh(wall)
    wall.data.materials.append(mat_wall())
    objs["wall"] = wall

    # Tunnel: a little wider than the opening and starting at the wall plane, so its side walls and
    # roof hide behind the arch: each jamb shows only the ceramic's own inner face, lit warm.
    tw = Ri + TUN_W
    tun = curve_from_paths("tunnel", [door_path(tw, 0, base - 0.3)], extrude=TUN_L / 2, fill="BOTH")
    tun.rotation_euler = (math.radians(90), 0, 0)
    tun.location = (0, TUN_L / 2, 0)
    tun = to_mesh(tun)
    import bmesh
    bm = bmesh.new(); bm.from_mesh(tun.data)
    bmesh.ops.delete(bm, geom=[f for f in bm.faces if abs(f.normal.z) > 0.9], context="FACES")
    bmesh.ops.reverse_faces(bm, faces=bm.faces[:])
    bm.to_mesh(tun.data); bm.free()
    tun.data.materials.append(mat_tunnel())
    objs["tunnel"] = tun

    # The lantern orb floats at DOT_H of the opening height, as in the flat mark. Sized and placed so
    # that, seen from the camera, it lines up with the mark's dot on the wall plane.
    cam_d = camera_distance()
    k = (cam_d + ORB_Y) / cam_d
    z_eye = cam_target_z()
    z_dot = base + DOT_H * (leg + Ri)
    z_orb = z_eye + (z_dot - z_eye) * k
    r_orb = MARK["Rd"] * k
    bpy.ops.mesh.primitive_uv_sphere_add(segments=96, ring_count=48, radius=r_orb, location=(0, ORB_Y, z_orb))
    orb = bpy.context.active_object
    for p in orb.data.polygons:
        p.use_smooth = True
    orb.data.materials.append(mat_orb())
    orb.visible_shadow = False
    objs["orb"] = orb
    # glow shell: a larger transparent sphere whose emission fades to nothing at its silhouette, so the
    # orb sits in a soft lantern corona (also seen in the floor's reflection)
    bpy.ops.mesh.primitive_uv_sphere_add(segments=96, ring_count=48, radius=r_orb * HALO_R, location=(0, ORB_Y, z_orb))
    halo = bpy.context.active_object
    for p in halo.data.polygons:
        p.use_smooth = True
    halo.data.materials.append(mat_halo())
    halo.visible_shadow = False
    halo.visible_diffuse = False
    objs["halo"] = halo

    bpy.ops.mesh.primitive_plane_add(size=3.0, location=(0, TUN_L - 0.002, z_orb), rotation=(math.radians(90), 0, 0))
    back = bpy.context.active_object
    back.data.materials.append(mat_backglow(BACK_REACH))
    objs["back"] = back

    bpy.ops.mesh.primitive_plane_add(size=1, location=(0, (TUN_L - 6.0) / 2, base))
    fl = bpy.context.active_object
    fl.scale = (16, 6 + TUN_L, 1)
    fl.data.materials.append(mat_floor())
    objs["floor"] = fl

    # Lights
    add_light("lantern", "POINT", (0, -0.20, base + 0.22), LANTERN * 0.7 + EMBER * 0.3, 9.0, size=0.15, glossy=False, shadow=False)
    add_light("core", "POINT", (0, ORB_Y, z_orb), LANTERN * 0.8 + CREAM * 0.2, CORE_W, size=r_orb, glossy=True)
    add_light("key", "AREA", (0, -3.0, 3.4), np.array([0.96, 0.89, 0.95]), 150.0, size=3.5, rot=(math.radians(42), 0, 0))
    add_light("fill", "AREA", (0, -4.0, 0.2), np.array([0.85, 0.72, 0.88]), 34.0, size=4.0, rot=(math.radians(88), 0, 0))
    # long thin strip straight above: a crisp highlight line along the crown's top edge
    add_light("strip", "AREA", (0, -0.42, 2.6), np.array([1.0, 0.95, 0.92]), 55.0, size=3.0, size_y=0.10)
    # warm rim from behind-low: separates the arch from the wall a touch
    add_light("rim", "AREA", (0, 0.6, base + 0.05), LANTERN, 6.0, size=1.2, rot=(math.radians(-90), 0, 0), glossy=False)

    camd = bpy.data.cameras.new("cam")
    camd.lens = CAM_LENS
    camd.sensor_width = 36
    cam = bpy.data.objects.new("cam", camd)
    bpy.context.collection.objects.link(cam)
    elev = math.radians(CAM_ELEV)
    tgt = np.array([0, 0, cam_target_z()])
    cam.location = tuple(tgt + np.array([0, -cam_d * math.cos(elev), cam_d * math.sin(elev)]))
    cam.rotation_euler = (math.pi / 2 - elev, 0, 0)
    sc.camera = cam
    return sc, objs

def cam_target_z():
    """Aim so that, on the wall plane, the arch spans ARCH_TOP..ARCH_FEET of the canvas."""
    return MARK["Ro"] - (CANVAS / 2 - ARCH_TOP) / UNIT

def camera_distance():
    view_h = CANVAS / UNIT                   # scene units visible vertically at the wall
    return view_h * CAM_LENS / 36.0

def render_to(path):
    bpy.context.scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    return read_img(path)

def render_icon_passes():
    paths = {k: os.path.join(WORK, f"render-{k}.png") for k in ("full", "fg", "bg")}
    if REUSE and all(os.path.exists(p) for p in paths.values()):
        return {k: read_img(p) for k, p in paths.items()}
    sc, objs = build_icon_scene()
    res = {}
    res["full"] = render_to(paths["full"])
    # foreground layer: arch + glowing opening, wall and floor held out
    sc.render.film_transparent = True
    for k in ("wall", "floor"):
        objs[k].is_holdout = True
    res["fg"] = render_to(paths["fg"])
    for k in ("wall", "floor"):
        objs[k].is_holdout = False
    # background layer: the plate without the arch (it still shadows and reflects)
    sc.render.film_transparent = False
    for k in ("arch", "orb", "halo"):
        objs[k].visible_camera = False
    res["bg"] = render_to(paths["bg"])
    return res

# ---------------------------------------------------------------- text (CoreText via swift)
def text(s, size, weight="regular", design="default", tracking=0.0):
    """Alpha mask of one line of text, trimmed to its ink horizontally; returns (alpha, baseline_y, cap_height)."""
    key = "".join(c if c.isalnum() else "_" for c in s)[:40]
    path = os.path.join(WORK, f"text-{key}-{size}-{weight}-{design}-{tracking}.png")
    r = subprocess.run(["swift", os.path.join(HERE, "text.swift"), path, s, str(size), weight, design, str(tracking)],
                       capture_output=True, text=True, check=True)
    f = r.stdout.split()
    base, cap = float(f[1]), float(f[3])
    a = read_img(path)[..., 3]
    ys, xs = np.where(a > 0.004)
    return a[:, xs.min():xs.max() + 1], base, cap

def ink_box(a):
    ys, xs = np.where(a > 0.02)
    return ys.min(), ys.max() + 1


# ================================================================ compositing
BLOOM_T = 0.72
WARM_SAT = 0.12
GLARE = 0.35
def bloom(rgb, k=1.0):
    """The light glows past the opening edge; keeps the hot core soft like a real lens."""
    lum = rgb @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    hot = np.clip((lum - BLOOM_T) / (1 - BLOOM_T), 0, 1)[..., None] * rgb
    return (blur(hot, 3) * 0.30 + blur(hot, 10) * 0.30 + blur(hot, 30) * 0.24 + blur(hot, 90) * 0.18) * k

def warm_grade(rgb, k=WARM_SAT):
    """AgX keeps the hot interior from clipping but bleaches it towards salmon; give the warm pixels
    their brand saturation back (ember / lantern), leaving the plum and the near-white core alone."""
    lum = (rgb @ np.array([0.2126, 0.7152, 0.0722], np.float32))[..., None]
    warm = np.clip((rgb[..., :1] - rgb[..., 2:3] - 0.12) / 0.25, 0, 1) * np.clip((0.97 - lum) / 0.12, 0, 1)
    return np.clip(lum + (rgb - lum) * (1 + k * warm), 0, None).astype(np.float32)

def orb_glare(rgb):
    """A soft lantern halo round the orb (only the near-white core feeds it)."""
    lum = rgb @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    core = np.clip((lum - 0.86) / 0.08, 0, 1)
    g = blur(core, 6) * 0.45 + blur(core, 18) * 0.45 + blur(core, 50) * 0.35 + blur(core, 120) * 0.15
    return (g[..., None] * (LANTERN * 0.75 + CREAM * 0.25) * GLARE).astype(np.float32)

def shoulder(rgb, knee=0.88, top=0.975):
    """Soft roll-off above `knee`, so the hot core never clips to flat white."""
    span = top - knee
    return np.where(rgb > knee, knee + span * (1 - np.exp(-(rgb - knee) / span)), rgb).astype(np.float32)

def finish_icon(full):
    """Full-bleed 1024 render -> macOS 26 icon: 824 continuous-corner body, edge light, drop shadow."""
    S, B = CANVAS, BODY
    rgb = full[..., :3]
    rgb = warm_grade(rgb)
    rgb = screen(rgb, bloom(rgb))
    rgb = screen(rgb, orb_glare(rgb))
    rgb = shoulder(rgb)
    rgb = np.clip(rgb + grain(S, S, 0.005), 0, 0.985)
    m = squircle(S, B)
    yy = np.linspace(0, 1, S, dtype=np.float32)[:, None]
    # inner edge highlight: a hairline bevel, bright along the top, fading down the sides
    ring = np.clip(m - squircle(S, B - 4.5), 0, 1)
    top = np.clip(1 - (yy - 0.10) / 0.55, 0.12, 1.0)
    k = (ring * top * 0.34)[..., None]
    rgb = rgb * (1 - k) + np.array([1.0, 0.93, 0.86], np.float32) * k
    # soft inner shade along the bottom edge (pressed-glass depth)
    edge = np.clip(m - blur(squircle(S, B - 12, cy=S / 2 - 7), 4), 0, 1) * (yy > 0.5)
    rgb = rgb * (1 - edge[..., None] * 0.28)
    canvas = np.zeros((S, S, 4), np.float32)
    sh1 = blur(squircle(S, B, cy=S / 2 + 5), 5) * 0.28
    sh2 = blur(squircle(S, B, cy=S / 2 + 14), 20) * 0.30
    canvas[..., 3] = 1 - (1 - sh1) * (1 - sh2)
    over(canvas, np.dstack([rgb, m]).astype(np.float32), 0, 0)
    return canvas

def sharpen(img, amt):
    o = img.copy()
    o[..., :3] = np.clip(img[..., :3] + amt * (img[..., :3] - blur(img[..., :3], 0.8)), 0, 1)
    return o

# Small sizes: the same drawing redrawn on the pixel grid (integer leg edges and baseline).
# Same framing as the big icon: arch ~66% of the body, crown a little above centre.
# The dot is an even number of pixels wide on the centre line, so it lands on whole pixels.
SMALL = {32: dict(cx=16, cy=16, Ro=9, Ri=5, base=24, Rd=2, dy=18),
         16: dict(cx=8, cy=8, Ro=5, Ri=3, base=12, Rd=1, dy=9)}
C_WALL_TOP, C_WALL_BOT, C_FLOOR = hx("2B2235"), hx("161019"), hx("120B13")
C_CROWN, C_LEG, C_EDGE = hx("624E6E"), hx("35263F"), hx("B4A3B6")
C_HOT = LANTERN * 0.55 + CREAM * 0.45

def small_icon(size):
    g = SMALL[size]
    ss = 8
    X, Y = grid(size, size, ss)
    body = squircle(size, BODY / CANVAS * size, ss=ss)
    ring_d, dot_d = sd_mark_parts(X, Y, **g)
    open_d = sd_door(X - g["cx"], Y, g["Ri"], g["cy"], g["base"])
    t = (Y / size)[..., None]
    col = C_WALL_TOP * (1 - t) + C_WALL_BOT * t
    below = (Y >= g["base"])[..., None]
    # floor with a warm reflection under the opening
    fx = np.exp(-((X - g["cx"]) / (g["Ri"] * 0.9)) ** 2)
    fy = np.exp(-((Y - g["base"]) / (size * 0.09)))
    refl = (fx * fy)[..., None] * (0.42 if size >= 32 else 0.3)
    floor = C_FLOOR * (1 - refl) + (LANTERN * 0.55 + EMBER * 0.45) * refl
    col = np.where(below, floor, col)
    # glowing opening: lantern round the orb, ember towards the rim (as in the big icon)
    d = (np.sqrt((X - g["cx"]) ** 2 + (Y - g["dy"]) ** 2) / (g["Ri"] * 1.7))[..., None]
    open_col = np.where(d < 0.5, C_HOT * (1 - d / 0.5) + LANTERN * (d / 0.5),
                        LANTERN * np.clip(1 - (d - 0.5) / 0.5, 0, 1) + EMBER * np.clip((d - 0.5) / 0.5, 0, 1))
    col = np.where((open_d <= 0)[..., None], open_col, col)
    # ceramic ring: lit crown fading to dusky legs, a crisp edge light along the top
    v = np.clip((Y - (g["cy"] - g["Ro"])) / (g["base"] - (g["cy"] - g["Ro"])), 0, 1)[..., None]
    ring_col = C_CROWN * (1 - v) + C_LEG * v
    if size >= 32:
        outer = sd_door(X - g["cx"], Y, g["Ro"], g["cy"], g["base"])
        hl = ((outer > -0.7) & (Y < g["cy"] - g["Ro"] * 0.6))[..., None]
        ring_col = np.where(hl, ring_col * 0.45 + C_EDGE * 0.55, ring_col)
    col = np.where((ring_d <= 0)[..., None], ring_col, col)
    col = np.where((dot_d <= 0)[..., None], CREAM, col)
    out = np.dstack([down(col, ss), body]).astype(np.float32)
    if size >= 32:   # faint contact shadow under the body, as in the big icon
        sh = np.zeros((size, size, 4), np.float32)
        sh[..., 3] = np.clip(np.roll(body, 1, axis=0) - body, 0, 1) * 0.35
        over(sh, out, 0, 0)
        out = sh
    return out

def menubar(scale):
    s = scale
    # 18 x 18 pt: the arch spans rows 1..16 (one empty row above and below at 1x, two at @2x), legs
    # 4 px on whole pixels; the dot sits on whole pixels with a 2 px (1x) / 5 px (@2x) gap to the legs.
    # (A 4 px dot at 1x keeps it readable; @2x uses 6 px, the mark's own proportion.)
    rd = 2 if s == 1 else 3
    a = mark_alpha(18 * s, 18 * s, cx=9 * s, cy=9 * s, Ro=8 * s, Ri=4 * s, base=17 * s, Rd=rd, dy=11 * s, ss=16)
    return layer(a, BLACK)

def mark_image(color, size=1024):
    g = mark_fit(size, size * 0.625)
    return layer(mark_alpha(size, size, ss=4, **g), color)

def text_layer(s_, size, color, weight="regular", design="default", tracking=0.0, opacity=1.0):
    a, base, cap = text(s_, size, weight, design, tracking)
    return layer(a, color, opacity), base, cap

def place(dst, src, x, y):
    over(dst, src, x, y)

def word(size, color):
    return text_layer("Burrow", size, color, "heavy", "rounded", -0.01)

def lockup(icon, color, width=1600):
    """Icon + logotype, transparent background."""
    I = 520
    ic = resize(icon, I)
    body = I * BODY / CANVAS
    margin = (I - body) / 2
    w, base, cap = word(250, color)
    gap = body * 0.17
    total = body + gap + w.shape[1]
    H = I
    out = np.zeros((H, width, 4), np.float32)
    x0 = (width - total) / 2
    place(out, ic, x0 - margin, 0)
    cy = H / 2
    place(out, w, x0 + body + gap, cy + cap / 2 - base)
    return out

def strata(h, w, seed, lines=10, glow=None, strength=1.0, ch=None, cw=None):
    """Faint sedimentary layers: wavy hairlines with slightly lighter bands, lit near the glow.
    Laid out for an h x w scene; ch x cw (default the same) is the canvas they are drawn on."""
    ch, cw = ch or h, cw or w
    rng = np.random.default_rng(seed)
    X, Y = np.meshgrid(np.arange(cw, dtype=np.float32) + 0.5, np.arange(ch, dtype=np.float32) + 0.5)
    acc = np.zeros((ch, cw), np.float32)
    band = np.zeros((ch, cw), np.float32)
    for k in range(lines):
        y0 = h * (0.08 + 0.92 * (k + rng.uniform(0.2, 0.8)) / lines)
        a1, a2 = rng.uniform(0.010, 0.030) * h, rng.uniform(0.004, 0.012) * h
        f1, f2 = rng.uniform(0.6, 1.3), rng.uniform(1.8, 3.4)
        p1, p2 = rng.uniform(0, 6.28), rng.uniform(0, 6.28)
        yk = y0 + a1 * np.sin(X / w * 6.283 * f1 + p1) + a2 * np.sin(X / w * 6.283 * f2 + p2)
        d = np.abs(Y - yk)
        acc += np.exp(-(d / max(0.6, h / 640 * 0.9)) ** 2) * rng.uniform(0.5, 1.0)
        band += (Y > yk) * (0.5 if k % 2 else -0.5) / lines
    out = acc * 0.055 + band * 0.02
    if glow is not None:
        out *= 0.35 + glow * 1.6
    return out * strength

def scene_bg(h, w, gx, gy, gr, seed=3, strata_k=1.0, glow_k=1.0, ch=None, cw=None, vig_floor=0.0):
    """Night-soil ground, faint tunnel strata, and a lantern glow centred on (gx, gy), the icon's
    centre: it is mostly hidden behind the icon and shows as a warm aura round its edges.
    The scene is laid out for h x w; ch x cw (default the same) is the canvas, so a larger canvas
    carries the ground on past the right and bottom edges. vig_floor stops the vignette there
    from running down to black."""
    ch, cw = ch or h, cw or w
    yy = np.clip(np.arange(ch, dtype=np.float32) / (h - 1), 0, 1)[:, None, None]
    rgb = (BURROW * 0.85 + VELVET * 0.08) * (1 - yy) + NIGHT * 0.92 * yy
    rgb = np.broadcast_to(rgb, (ch, cw, 3)).copy()
    g_far = radial(ch, cw, gx, gy, gr * 1.6)
    st = strata(h, w, seed, glow=g_far, strength=strata_k, ch=ch, cw=cw)[..., None]
    rgb = rgb + st * (VELVET * 0.6 + LANTERN * 0.2 * g_far[..., None] + 0.15)
    # a faint plum lift so the aura does not sit on flat black, then the lantern aura itself
    # (lantern-heavy: an ember-heavy haze over plum turns brown)
    rgb = screen(rgb, VELVET * g_far[..., None] * 0.22 * glow_k)
    g = radial(ch, cw, gx, gy, gr) ** 1.3
    rgb = screen(rgb, (LANTERN * 0.9 + EMBER * 0.1) * g[..., None] * 0.20 * glow_k)
    X, Y = np.meshgrid(-1 + 2 * np.arange(cw) / (w - 1), -1 + 2 * np.arange(ch) / (h - 1))
    vig = 1 - 0.28 * (X ** 2 * 0.6 + Y ** 2) ** 1.2
    if vig_floor > 0:   # smooth max(vig, floor)
        vig = (vig + vig_floor + np.sqrt((vig - vig_floor) ** 2 + 0.05 ** 2)) / 2
    rgb = rgb * np.clip(vig, 0, 1)[..., None]
    rgb = np.clip(rgb + grain(ch, cw, 0.006, seed), 0, 1)
    return np.dstack([rgb, np.ones((ch, cw))]).astype(np.float32)

def hero(icon, W, H, icon_px, word_px, tag_px, extra=None):
    body = icon_px * BODY / CANVAS
    margin = (icon_px - body) / 2
    w, wb, wcap = word(word_px, CREAM)
    t, tb, tcap = text_layer("A beautiful home for Mole", tag_px, CREAM, "medium", "rounded", 0.0, 0.72)
    gap = body * 0.20
    block_w = max(w.shape[1], t.shape[1])
    total = body + gap + block_w
    x0 = (W - total) / 2
    cy = H / 2
    img = scene_bg(H, W, x0 + body / 2, cy, body * 0.78, strata_k=1.05)
    place(img, resize(icon, icon_px), x0 - margin, cy - icon_px / 2)
    tx = x0 + body + gap
    line_gap = tag_px * 0.95
    block_h = wcap + line_gap + tag_px * 0.72
    top = cy - block_h / 2
    if extra is not None:
        top -= extra[1] / 2
    place(img, w, tx - 2, top + wcap - wb)
    place(img, t, tx, top + wcap + line_gap + tcap - tb)
    if extra is not None:
        extra[0](img, tx, top + wcap + line_gap + tcap + extra[1] * 0.75)
    return img

def features_line(size):
    """'Clean . Uninstall . Analyze . Monitor' with tiny mint separators (the only mint in the pack)."""
    parts = [text_layer(s_, size, CREAM, "medium", "rounded", 0.01, 0.55) for s_ in ("Clean", "Uninstall", "Analyze", "Monitor")]
    def draw(img, x, y):
        for i, (lay, b, cap) in enumerate(parts):
            place(img, lay, x, y - b)
            x += lay.shape[1]
            if i < len(parts) - 1:
                d = int(size * 1.1)
                dot = mint_dot(size * 0.11)
                place(img, dot, x + d / 2 - dot.shape[1] / 2, y - cap * 0.5 - dot.shape[0] / 2)
                x += d
    return draw

def mint_dot(r):
    n = int(math.ceil(r * 2 + 2))
    X, Y = grid(n, n, 8)
    a = down(((X - n / 2) ** 2 + (Y - n / 2) ** 2 <= r * r).astype(np.float32), 8)
    return layer(a, MINT, 0.9)

# Finder pins the DMG background to the window's top-left corner and paints white wherever the picture
# runs out (the view's background colour is ignored once a picture is set), so the picture is far
# bigger than the window: the 660 x 420 pt composition sits top-left, its ground carries on for
# DMG_FADE pt past the right and bottom edges, then settles to one flat colour out to DMG_CANVAS,
# enough for a full-screen window on a 6K display. The flat area compresses to almost nothing.
DMG_DESIGN = (660, 420)
DMG_CANVAS = (3200, 2000)
DMG_FADE = 360

def dmg_background(scale):
    """Finder window, 660 x 420 pt of content. Drop zones: app at (170, 210), Applications at (490, 210).
    Returns the full canvas and the dither weight (zero over the flat colour, so it stays exactly flat)."""
    s = scale
    W, H = DMG_DESIGN[0] * s, DMG_DESIGN[1] * s
    F = DMG_FADE * s
    EW, EH = W + F, H + F
    img = scene_bg(H, W, 170 * s, 210 * s, 78 * s, seed=11, strata_k=0.8, glow_k=0.8, ch=EH, cw=EW, vig_floor=0.45)
    # straight arrow between the zones: clean cream stroke with a symmetric chevron head
    y, x0, x1 = 210.0, 268.0, 392.0
    wd = 3.2
    a = stroke_path(W, H, [(x0 * s, y * s), ((x1 - 1.0) * s, y * s)], [wd * s, wd * s], ss=4)
    for sgn in (-1, 1):
        ang = math.radians(40) * sgn
        tail = (x1 - 13.0 * math.cos(ang), y + 13.0 * math.sin(ang))
        a = np.maximum(a, stroke_path(W, H, [(tail[0] * s, tail[1] * s), (x1 * s, y * s)], [wd * s, wd * s], ss=4))
    over(img, layer(a, CREAM, 0.70), 0, 0)
    # Finder draws icon labels black whenever the window has a background picture, in Dark Mode too,
    # so each label gets a cream plate to sit on. Where Finder puts them (measured on macOS 26, 13 pt
    # text, 128 pt icons): centred on the icon's x, cap top at y = 288.5 pt, baseline at 297.5 pt.
    X, Y = np.meshgrid(np.arange(W) + 0.5, np.arange(H) + 0.5)
    for name, cx in (("Burrow", 170), ("Applications", 490)):
        hw = text(name, 13 * s)[0].shape[1] / 2 + 11 * s   # half the label's ink width, plus padding
        hh = 11 * s
        d = np.hypot(np.maximum(np.abs(X - cx * s) - (hw - hh), 0), Y - 293.5 * s) - hh   # capsule distance
        over(img, layer(np.clip(0.5 - d, 0, 1).astype(np.float32), CREAM, 0.92), 0, 0)
    t, tb, tcap = text_layer("First launch: System Settings \u2192 Privacy & Security \u2192 Open Anyway",
                             13 * s, CREAM, "medium", "default", 0.0, 0.75)
    place(img, t, (W - t.shape[1]) / 2, 392 * s - tb)
    # past the composition, ease the ground into the flat colour of the rest of the canvas
    flat = NIGHT * 0.92 * 0.45
    X, Y = np.meshgrid(np.arange(EW) + 0.5, np.arange(EH) + 0.5)
    d = np.hypot(np.maximum(X - W, 0), np.maximum(Y - H, 0)) / F
    m = (1 - smooth(0, 1, d)).astype(np.float32)
    img[..., :3] = flat + (img[..., :3] - flat) * m[..., None]
    CW, CH = DMG_CANVAS[0] * s, DMG_CANVAS[1] * s
    out = np.empty((CH, CW, 4), np.float32)
    out[..., :3], out[..., 3] = flat, 1
    out[:EH, :EW] = img
    weight = np.zeros((CH, CW), np.float32)
    weight[:EH, :EW] = m > 0
    return out, weight

def mark_small(color, size):
    g = mark_fit(size, size * 0.625)
    return layer(mark_alpha(size, size, ss=4, **g), color)

PALETTE = [("Night-soil", NIGHT, "15111B"), ("Burrow", BURROW, "231B2B"), ("Velvet", VELVET, "3A2E45"),
           ("Lantern", LANTERN, "FFB23F"), ("Ember", EMBER, "F2703A"), ("Mint", MINT, "3DDC97"),
           ("Cream", CREAM, "FFF4E2")]

def presentation(icon, smalls, sizes, hero_img, social_img, dmg_img):
    W, H, M = 1600, 900, 40
    P = np.zeros((H, W, 4), np.float32); P[..., 3] = 1
    yy = np.linspace(0, 1, H, dtype=np.float32)[:, None, None]
    P[:, :800, :3] = (BURROW * 0.75 + NIGHT * 0.25) * (1 - yy) + NIGHT * yy
    P[:, 800:, :3] = CREAM * (1 - yy * 0.5) + np.array([1, 1, 1], np.float32) * yy * 0.5
    sub_d, sub_l = CREAM * 0.5 + NIGHT * 0.5, INK * 0.5 + CREAM * 0.5

    def label(s_, x, y, col, center=True, size=17):
        lay, b, cap = text_layer(s_, size, col, "medium", "default", 0.01)
        place(P, lay, x - (lay.shape[1] / 2 if center else 0), y - b)

    # lockups, each labelled with the file it corresponds to
    for x0, ink, sub, name in ((0, CREAM, sub_d, "wordmark.png \u00b7 cream type, for dark backgrounds"),
                               (800, INK, sub_l, "wordmark-dark.png \u00b7 ink type, for light backgrounds")):
        place(P, resize(icon, 300), x0 + 30, 16)
        w, b, cap = word(118, ink)
        place(P, w, x0 + 330, 166 + cap / 2 - b)
        label(name, x0 + M + 22, 322, sub, center=False, size=15)

    # palette
    n, gap = len(PALETTE), 14
    sw = (800 - 2 * M - gap * (n - 1)) // n
    x, y = M, 352
    for nm, c, hx_ in PALETTE:
        over(P, solid(56, sw, CREAM, 0.16), x - 1, y - 1)
        over(P, solid(54, sw - 2, c), x, y)
        label(nm, x, y + 78, CREAM * 0.8 + NIGHT * 0.2, center=False, size=14)
        label("#" + hx_, x, y + 98, sub_d, center=False, size=13)
        x += sw + gap

    # icon sizes
    x, base_y = M + 10, 612
    for s_ in (128, 64, 32, 16):
        place(P, sizes[s_], x, base_y - s_)
        label(f"{s_} px", x + s_ / 2, base_y + 30, sub_d)
        x += s_ + 44
    x += 4
    for s_ in (32, 16):
        place(P, nearest(smalls[s_], 128 // s_), x, base_y - 128)
        label(f"{s_} px \u00d7{128 // s_}", x + 64, base_y + 30, sub_d)
        x += 128 + 26

    # mark and menu bar template
    mk = mark_small(LANTERN, 150)
    place(P, mk, M - 15, 680)
    label("Mark", M + 60, 868, sub_d)
    bx, by = 260, 716
    over(P, solid(52, 320, BURROW * 1.25 + VELVET * 0.1), bx, by)
    mb2 = menubar(2); mb2[..., :3] = CREAM
    place(P, resize(mb2, 18), bx + 22, by + 17)
    label("Menu bar template, 18 pt", bx, by + 90, sub_d, center=False)
    mb1 = menubar(1); mb1[..., :3] = CREAM
    over(P, solid(18 * 6 + 24, 18 * 6 + 24, BURROW * 1.25 + VELVET * 0.1), 800 - M - 132, 700)
    place(P, nearest(mb1, 6), 800 - M - 120, 712)
    label("18 px \u00d76", 800 - M - 66, 868, sub_d)

    # right: hero, DMG, social, mark (40 px margins)
    place(P, resize(hero_img, 720, 288), 840, 352)
    label("README hero", 840 + 360, 664, sub_l)
    place(P, resize(dmg_img, 264, 168), 840, 690)
    label("DMG", 840 + 132, 885, sub_l)
    place(P, resize(social_img, 320, 160), 1124, 694)
    label("Social card", 1124 + 160, 885, sub_l)
    mk = mark_small(INK, 110)
    g = mark_fit(110, 110 * 0.625)
    ink_r = g["cx"] + g["Ro"]
    mx = W - M - ink_r
    place(P, mk, mx, 704)
    label("Mark", mx + g["cx"], 885, sub_l)
    return P

def write(name, img, dither=True):
    """Continuous-tone assets are dithered before 8-bit quantisation (smooth dark gradients would band);
    flat artwork (marks, template, pixel-drawn small icons) is written exactly."""
    write_png(os.path.join(OUT, name), img, dither=dither, seed=zlib.crc32(name.encode()))
    print("wrote", name, img.shape[1], "x", img.shape[0])

def main():
    passes = render_icon_passes()
    icon = finish_icon(passes["full"])
    write("icon-1024.png", icon)
    write("layer-background.png", np.dstack([np.clip(passes["bg"][..., :3] + grain(CANVAS, CANVAS, 0.005), 0, 1),
                                             np.ones((CANVAS, CANVAS), np.float32)]))
    write("layer-foreground.png", passes["fg"])

    sizes = {}
    for s_ in (512, 256, 128, 64):
        im = resize(icon, s_)
        if s_ <= 128:
            im = sharpen(im, 0.35 if s_ == 128 else 0.5)
        sizes[s_] = im
        write(f"icon-{s_}.png", im)
    smalls = {s_: small_icon(s_) for s_ in (32, 16)}
    sizes.update(smalls)
    for s_ in (32, 16):
        write(f"icon-{s_}.png", smalls[s_], dither=False)
    write("about-icon.png", sizes[512])
    iconset = os.path.join(OUT, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    full = dict(sizes); full[1024] = icon
    for pt in (16, 32, 128, 256, 512):
        for px, nm in ((pt, f"icon_{pt}x{pt}.png"), (pt * 2, f"icon_{pt}x{pt}@2x.png")):
            write_png(os.path.join(iconset, nm), full[px], dither=px >= 64, seed=px)

    write("mark.png", mark_image(BLACK), dither=False)
    write("mark-cream.png", mark_image(CREAM), dither=False)
    write("mark-lantern.png", mark_image(LANTERN), dither=False)
    write("menubar-template.png", menubar(1), dither=False)
    write("menubar-template@2x.png", menubar(2), dither=False)

    write("wordmark.png", lockup(icon, CREAM))
    write("wordmark-dark.png", lockup(icon, INK))
    hero_img = hero(icon, 1600, 640, 440, 150, 44)
    write("readme-hero.png", hero_img)
    social_img = hero(icon, 1280, 640, 400, 132, 38, extra=(features_line(27), 56))
    write("social-preview.png", social_img)
    (d1, w1), (d2, w2) = dmg_background(1), dmg_background(2)
    write("dmg-background.png", d1, dither=w1)
    write("dmg-background@2x.png", d2, dither=w2)
    dmg_view = d2[:DMG_DESIGN[1] * 2, :DMG_DESIGN[0] * 2]   # what the window shows when it opens
    write("presentation.png", presentation(icon, smalls, sizes, hero_img, social_img, dmg_view))

if os.environ.get("BRAND_NO_MAIN") != "1":
    main()
    print("DONE")
