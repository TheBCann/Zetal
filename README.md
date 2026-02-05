# Zetal Engine

A high-performance, from-scratch 3D graphics engine for macOS written in **Zig**.

Zetal bypasses standard bindings (like GLFW or SDL) and interacts directly with the **Objective-C Runtime** and **Metal API** to create windows, handle events, and render 3D geometry entirely from Zig code.

## 🚀 Features

* **Zero Dependencies:** No C/C++ headers, no external libraries, no bindings. Just pure Zig talking to the kernel.
* **Native Windowing:** Custom implementation of `NSApplication` and `NSWindow` via the Objective-C runtime.
* **Metal Rendering:** Full pipeline control—Devices, Command Queues, and Render Encoders.
* **3D Math Library:** Custom linear algebra implementation (Matrices, Vectors, Perspective Projection).
* **Shader Compilation:** Runtime compilation of raw MSL (Metal Shading Language) strings.
* **Depth Buffering:** Full Z-Buffer implementation with `Depth32Float` textures and `Less` comparison depth states.
* **Uniform Buffers:** Dynamic CPU-to-GPU data transfer for transformation matrices.

## 🛠️ Build & Run

Ensure you have the latest **Zig Nightly** installed (tested on 0.16.0-dev).

### Run the Engine
Compiles the engine, math library, and shaders, then launches the window.
zig build run

Run Tests

Verifies GPU connectivity and memory mapping.

zig build test --summary all

📂 Project Structure

    src/root.zig: The core Metal API wrappers (Device, Library, CommandQueue).

    src/window.zig: The AppKit logic (Window creation, Event polling, MetalView).

    src/main.zig: The application loop (Input, Math updates, Rendering).

    src/render/:

        math.zig: 4x4 Matrix and vector math.

        pipeline.zig: Render Pipeline and Depth Stencil state descriptors.

        shader.zig: Raw Metal Shading Language (MSL) source code.

        vertex.zig: Geometry definitions (Vertex structs, Pyramid data).

📝 Roadmap

Core Graphics

    [x] Connect to System Default Device

    [x] Create Native Window (AppKit)

    [x] Compile MSL Shaders at Runtime

    [x] Draw a Triangle (Vertex Buffers)

    [x] 3D Transformations (Uniform Buffers & Matrix Math)

<<<<<<< HEAD
    [x] Depth Buffering (Z-Testing & Depth Textures)

Next Steps

    [ ] Input Handling (Keyboard/Mouse State)

    [ ] Camera System (WASD Movement)

    [ ] Texture Mapping (Loading Images)

    [ ] Model Loading (OBJ/GLTF)
||||||| parent of 85186d4 (feat: implemented WASD flying camera, input handling, and 3D math tests)
    [ ] Draw a Triangle (The Hello World of Graphics)
=======
    [x] Depth Buffering (Z-Testing & Depth Textures)

Next Steps

    [x] Input Handling (Keyboard/Mouse State)

    [x] Camera System (WASD Movement)

    [ ] Texture Mapping (Loading Images)

    [ ] Model Loading (OBJ/GLTF)
>>>>>>> 85186d4 (feat: implemented WASD flying camera, input handling, and 3D math tests)
