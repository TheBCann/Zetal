#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "=== Zetal Compute Physics Deploy ==="
echo ""

# Safety: backup
if [ ! -d src.bak2 ]; then
  cp -r src src.bak2
  echo "✓ Backed up src/ → src.bak2/"
else
  echo "• src.bak2/ already exists, skipping backup"
fi

# 1. New files
cp deploy/src/render/compute.msl src/render/
echo "✓ Created render/compute.msl (GPU compute kernels)"

cp deploy/src/render/compute.zig src/render/compute.zig
echo "✓ Created render/compute.zig (compute physics manager)"

# 2. Replace files
cp deploy/src/ecs/systems.zig src/ecs/systems.zig
echo "✓ Updated ecs/systems.zig (+ collision response, floor enforcement)"

cp deploy/src/scene.zig src/scene.zig
echo "✓ Updated scene.zig (70% static + 30% dynamic cubes)"

cp deploy/src/main.zig src/main.zig
echo "✓ Updated main.zig (GPU compute physics wired in)"

# 3. Patch render/root.zig — add compute export
if ! grep -q 'compute' src/render/root.zig; then
  # Add after the skybox line
  sed -i '' '/pub const skybox/a\
pub const compute = @import("compute.zig");
' src/render/root.zig
  echo "✓ Patched render/root.zig (added compute export)"
else
  echo "• render/root.zig already has compute export"
fi

# 4. Patch render/device.zig — add 3 methods to existing structs

# 4a. Add createComputePipelineState to MetalDevice (before closing '};')
if ! grep -q 'createComputePipelineState' src/render/device.zig; then
  # Find the last function in MetalDevice (createShadowMap) and add after its closing brace
  cat >>/tmp/zetal_compute_device_patch.txt <<'PATCH'

    pub fn createComputePipelineState(self: MetalDevice, function: MetalFunction) ?MetalComputePipelineState {
        const sel = objc.getSelector("newComputePipelineStateWithFunction:error:");
        const Fn = *const fn (?*anyopaque, ?objc.Selector, ?objc.Object, ?*anyopaque) callconv(.c) ?objc.Object;
        const msg: Fn = @ptrCast(&objc.objc_msgSend);
        if (msg(self.handle, sel, function.handle, null)) |p| return MetalComputePipelineState{ .handle = p };
        return null;
    }
PATCH
  # Insert before the final '};' of MetalDevice
  # MetalDevice is the last struct in the file, so its closing '};' is the last one
  # We'll use python for precision
  python3 -c "
import re
with open('src/render/device.zig', 'r') as f:
    content = f.read()

method = '''
    pub fn createComputePipelineState(self: MetalDevice, function: MetalFunction) ?MetalComputePipelineState {
        const sel = objc.getSelector(\"newComputePipelineStateWithFunction:error:\");
        const Fn = *const fn (?*anyopaque, ?objc.Selector, ?objc.Object, ?*anyopaque) callconv(.c) ?objc.Object;
        const msg: Fn = @ptrCast(&objc.objc_msgSend);
        if (msg(self.handle, sel, function.handle, null)) |p| return MetalComputePipelineState{ .handle = p };
        return null;
    }
'''

# Find the last '};' which closes MetalDevice
last_close = content.rfind('};')
content = content[:last_close] + method + '\n' + content[last_close:]

with open('src/render/device.zig', 'w') as f:
    f.write(content)
"
  rm -f /tmp/zetal_compute_device_patch.txt
  echo "✓ Patched device.zig: added MetalDevice.createComputePipelineState"
else
  echo "• device.zig already has createComputePipelineState"
fi

# 4b. Add createComputeCommandEncoder + waitUntilCompleted to MetalCommandBuffer
if ! grep -q 'createComputeCommandEncoder' src/render/device.zig; then
  python3 -c "
with open('src/render/device.zig', 'r') as f:
    content = f.read()

methods = '''
    pub fn createComputeCommandEncoder(self: MetalCommandBuffer) ?MetalComputeCommandEncoder {
        const sel = objc.getSelector(\"computeCommandEncoder\");
        const Fn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) ?objc.Object;
        const msg: Fn = @ptrCast(&objc.objc_msgSend);
        if (msg(self.handle, sel)) |p| return MetalComputeCommandEncoder{ .handle = p };
        return null;
    }

    pub fn waitUntilCompleted(self: MetalCommandBuffer) void {
        const sel = objc.getSelector(\"waitUntilCompleted\");
        const Fn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) void;
        const msg: Fn = @ptrCast(&objc.objc_msgSend);
        msg(self.handle, sel);
    }
'''

# Find the closing '};' of MetalCommandBuffer
# It's the struct that contains 'createRenderCommandEncoder'
# Find that function, then find the next '};' after its block
marker = 'pub fn commit(self: MetalCommandBuffer)'
pos = content.find(marker)
if pos == -1:
    print('ERROR: could not find MetalCommandBuffer.commit')
    exit(1)

# Find the '};' that closes MetalCommandBuffer after commit
# commit's closing brace, then the struct's closing brace
close_pos = content.find('};', pos)
content = content[:close_pos] + methods + '\n' + content[close_pos:]

with open('src/render/device.zig', 'w') as f:
    f.write(content)
"
  echo "✓ Patched device.zig: added MetalCommandBuffer.createComputeCommandEncoder + waitUntilCompleted"
else
  echo "• device.zig already has createComputeCommandEncoder"
fi

echo ""
echo "=== Deploy Complete ==="
echo ""
echo "New files:"
echo "  src/render/compute.msl    — Metal compute kernels (3 passes)"
echo "  src/render/compute.zig    — GPU buffer management + dispatch"
echo ""
echo "Modified files:"
echo "  src/render/device.zig     — +createComputePipelineState, +createComputeCommandEncoder, +waitUntilCompleted"
echo "  src/render/root.zig       — +compute export"
echo "  src/ecs/systems.zig       — +resolveCollisionPairs, +enforceFloor"
echo "  src/scene.zig             — 70/30 static/dynamic cube mix"
echo "  src/main.zig              — GPU compute physics pipeline"
echo ""
echo "Run: zig build -Doptimize=ReleaseSafe && ./zig-out/bin/Zetal"
echo "Restore: rm -rf src && cp -r src.bak2 src"
