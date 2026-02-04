Zetal

A lightweight, high-performance graphics library for macOS written in Zig.

This project provides direct bindings to Apple's Metal API without using Objective-C or Swift. It interacts directly with the Objective-C runtime to create devices, command queues, and compiled shaders entirely from Zig code.
🚀 Features

    Zero Dependencies: No external C or Objective-C headers required. Everything is bridged dynamically at runtime.

    Pure Zig: All logic, including the build system, is written in Zig.

    Metal Device Access: Successfully connects to the default system GPU (e.g., Apple M-Series).

    Command Submission: Implements the full Device -> CommandQueue -> CommandBuffer lifecycle.

    Shader Compilation: Compiles raw MSL (Metal Shading Language) strings into MTLLibrary objects at runtime.

🛠️ Build & Run

Ensure you have the latest Zig Nightly installed (tested on 0.16.0-dev).
Run the Demo App

This compiles the library and links it to a sample executable (src/main.zig).
Bash

zig build run

Run Tests

Verifies the connection to the GPU and ensuring the command pipeline works correctly.
Bash

zig build test --summary all

📂 Project Structure

    src/root.zig: The core library. Contains the MetalDevice, MetalCommandQueue, and MetalCommandBuffer structs.

    src/main.zig: The example application that imports the library and runs a smoke test.

    build.zig: The build configuration that links the Metal, Foundation, and objc system frameworks.

📝 Roadmap

    [x] Connect to System Default Device

    [x] Create Command Queue

    [x] Submit Command Buffer

    [x] Compile MSL Shaders

    [ ] Create Render Pipeline State

    [ ] Draw a Triangle (The Hello World of Graphics)
