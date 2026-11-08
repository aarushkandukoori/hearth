// License notices Hearth must ship with the app (shown on You > About).

enum ThirdPartyLicenses {
    /// Pie (pie-project/pie), Apache License 2.0: its NOTICE file, which Apache 2.0 asks to be passed on.
    /// Pie's C library and Swift package are linked into the app (ios/Vendor/PieSwift); the full license
    /// is at https://www.apache.org/licenses/LICENSE-2.0 and in ios/Vendor/PieSwift/LICENSE.
    static let pieNotice = """
Pie (pie-project)
Copyright 2025 Pie Team

This product includes software developed at the Pie project, licensed under the
Apache License, Version 2.0 (see LICENSE).

It also includes or is derived from the following third-party work.

--------------------------------------------------------------------------------
XGrammar
https://github.com/mlc-ai/xgrammar
Apache License 2.0
Copyright (c) 2024 by XGrammar Contributors

  The constrained-decoding engine in `crates/grammar` is a Rust rewrite derived
  in part from XGrammar; parts of its test suite are ported from XGrammar's.

--------------------------------------------------------------------------------
FlashInfer
https://github.com/flashinfer-ai/flashinfer
Apache License 2.0
Copyright (c) 2023-2025 by FlashInfer team
Copyright (c) 2022-2024, NVIDIA CORPORATION. All rights reserved.

  Internalized, not vendored: the attention code under
  `crates/kernels-cuda/kernels/attn/fa2/` and the peer all-reduce in
  `crates/kernels-cuda/kernels/collective/p2p.cuh` (which FlashInfer adapts
  from vLLM, Copyright contributors to the vLLM project) derive from
  FlashInfer v0.6.15, cut to what Pie uses and renamed into its namespaces;
  each file keeps its copyright header. crates/kernels-cuda/NOTICE lists the
  changes.

--------------------------------------------------------------------------------
MLX
https://github.com/ml-explore/mlx
MIT License
Copyright (c) 2023 Apple Inc.

  Internalized, not vendored: the GEMM tile under
  `crates/kernels-metal/kernels/prim/gemm_*.h` and the affine matmul and
  matvec kernels in `crates/kernels-metal/kernels/linear/` derive from MLX,
  renamed into Pie's namespaces; each file keeps its copyright and permission
  notice. crates/kernels-metal/NOTICE lists the files and the changes.

--------------------------------------------------------------------------------
NIXL
https://github.com/ai-dynamo/nixl
Apache License 2.0
SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES.
All rights reserved.

  `crates/transport/src/backends/nixl/wrapper.h` is NIXL's C API header.

--------------------------------------------------------------------------------
component-init
https://github.com/dicej/component-init
Apache License 2.0 with LLVM exception

  `instrument()` and `apply()` in `crates/runtime/src/inferlet/python/snapshot.rs`
  are adapted from the `component_init_transform` crate, as that file's header
  states.
"""

    /// Pie's C library (libpie.a, built by ios/scripts/build-pie.sh from pie-project/pie at 6168f025d) is Rust,
    /// and besides Pie's own crates it compiles in open-source crates from crates.io, e.g. wasmtime
    /// (Apache-2.0 WITH LLVM-exception), tokio (MIT) and serde (MIT OR Apache-2.0). Their licenses, from
    /// `cargo tree -p pie-c --target aarch64-apple-ios -e normal --format '{p} {l}'` in a Pie checkout at that
    /// commit, are all permissive: mostly MIT and/or Apache 2.0, some BSD, ISC, Zlib, Unicode and similar.
    static let pieCratesNote = """
Pie's library is written in Rust and includes open-source Rust crates, such as wasmtime, tokio and serde. \
Each keeps its own license: MIT, Apache 2.0 and similar permissive licenses. Pie's Cargo.lock at \
github.com/pie-project/pie (commit 6168f025d) lists them all, with their versions.
"""

    /// The MIT License, given once for every crate in Pie's library that uses it.
    static let mitLicense = """
MIT License

Copyright (c) the authors of each crate, as named in its own license file

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and \
associated documentation files (the "Software"), to deal in the Software without restriction, including \
without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the \
following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial \
portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT \
LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO \
EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER \
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE \
USE OR OTHER DEALINGS IN THE SOFTWARE.
"""
}
