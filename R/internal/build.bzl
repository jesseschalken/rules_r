# Copyright 2018 The Bazel Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

load(
    "@com_grail_rules_r//internal:shell.bzl",
    _sh_quote_args = "sh_quote_args",
)
load(
    "@com_grail_rules_r//R/internal:common.bzl",
    _build_path_export = "build_path_export",
    _count_group_matches = "count_group_matches",
    _env_vars = "env_vars",
    _executables = "executables",
    _flatten_pkg_deps_list = "flatten_pkg_deps_list",
    _library_deps = "library_deps",
    _makevars_files = "makevars_files",
    _package_dir = "package_dir",
    _runfiles = "runfiles",
    _srcs_dir = "srcs_dir",
    _tests_dir = "tests_dir",
)
load("@com_grail_rules_r//R:providers.bzl", "RLibrary", "RPackage")

# From the global R Makeconf.
_NATIVE_SOURCE_EXTS = [
    "c",
    "cc",
    "cpp",
    "m",
    "mm",
    "M",
    "f",
    "f95",
    "f90",
]

_NATIVE_HDR_EXTS = [
    "h",
    "hpp",
]

# From https://cran.r-project.org/doc/manuals/r-release/R-exts.html#DOCF13.
_R_SOURCE_EXTS = [
    "R",
    "S",
    "q",
    "r",
    "s",
]

_SOURCE_EXTS = _NATIVE_SOURCE_EXTS + _R_SOURCE_EXTS

def _package_name(ctx):
    # Package name from attribute with fallback to label name.

    pkg_name = ctx.attr.pkg_name
    if pkg_name == "":
        pkg_name = ctx.label.name
    return pkg_name

def _strip_path_prefixes(iterable, prefixes):
    # Given an iterable of paths and an iterable of prefixes, removes the
    # prefixes. Matching stops at the first non-empty prefix match.

    res = []
    for s in iterable:
        for p in prefixes:
            if not p:
                continue
            if not s or s == p:
                s = "."
                break
            elif s.startswith(p + "/"):
                s = s[(len(p) + 1):]
                break
        res.append(s)
    return res

def _link_info(dep, root_path):
    # Returns libraries to link from a cc_dep, giving preference to PIC.
    libs = []
    c_so_files = []
    c_libs_flags = []
    c_libs_flags_short = []

    # TODO: In the dependency graph, a static archive might already contain the
    # symbols from its child dependencies, in which case we don't need to link
    # the child dependency. For example, we don't need to link Rcpp.so in
    # tests/exampleC, but bazel still provides Rcpp.so as a linker input here.
    linker_inputs = dep[CcInfo].linking_context.linker_inputs.to_list()
    for linker_input in linker_inputs:
        for library_to_link in linker_input.libraries:
            dynamic_library = False
            if library_to_link.pic_static_library != None:
                l = library_to_link.pic_static_library
            elif library_to_link.static_library != None:
                l = library_to_link.static_library
            elif library_to_link.interface_library != None:
                l = library_to_link.interface_library
            elif library_to_link.dynamic_library != None:
                dynamic_library = True
                l = library_to_link.dynamic_library
            else:
                fail("unreachable")

            libs.append(l)

            if dynamic_library:
                c_so_files.append(l)
                continue

            c_libs_flags.append(root_path + l.path)
            c_libs_flags_short.append(root_path + l.short_path)

        c_libs_flags.extend(linker_input.user_link_flags)
        c_libs_flags_short.extend(linker_input.user_link_flags)

    return struct(
        c_libs_flags = c_libs_flags,
        c_libs_flags_short = c_libs_flags_short,
        c_so_files = c_so_files,
        libs = libs,
    )

def _cc_deps(ctx, instrumented):
    # Returns information for native code compilation.

    cc_deps = ctx.attr.cc_deps

    # Give absolute paths to R.
    root_path = "_EXEC_ROOT_"

    # bazel currently instruments all cc libraries if instrumentation is enabled.
    instrumented_cc_deps = False
    if (ctx.configuration.coverage_enabled and
        (ctx.coverage_instrumented() or
         # TODO: Remove cc_deps below when cc_library targets respect
         # instrumentation_filter.
         cc_deps or
         any([ctx.coverage_instrumented(dep) for dep in cc_deps]))):
        instrumented_cc_deps = True

    # Keep the original order of linker flags, and do not remove duplicates.
    # https://stackoverflow.com/a/409470
    libs = []
    c_so_files = []
    c_libs_flags = []
    c_libs_flags_short = []
    for dep in cc_deps:
        link_info = _link_info(dep, root_path)
        libs.extend(link_info.libs)
        c_so_files.extend(link_info.c_so_files)
        c_libs_flags.extend(link_info.c_libs_flags)
        c_libs_flags_short.extend(link_info.c_libs_flags_short)

    hdrs = depset(transitive = [d[CcInfo].compilation_context.headers for d in cc_deps])
    hdrs_roots = depset([hdr.root.path for hdr in hdrs.to_list()]).to_list()
    defines = depset(transitive = [d[CcInfo].compilation_context.defines for d in cc_deps]).to_list()
    quote_includes = depset(transitive = [d[CcInfo].compilation_context.quote_includes for d in cc_deps]).to_list()
    system_includes = depset(transitive = [d[CcInfo].compilation_context.system_includes for d in cc_deps]).to_list()
    includes = depset(transitive = [d[CcInfo].compilation_context.includes for d in cc_deps]).to_list()

    c_cpp_flags = []
    c_cpp_flags_short = []
    for i in defines:
        c_cpp_flags += ["-D" + i]
        c_cpp_flags_short += ["-D" + i]
    for i in quote_includes:
        c_cpp_flags += ["-iquote " + root_path + i]
    for i in system_includes:
        c_cpp_flags += ["-isystem " + root_path + i]
    for i in includes:
        c_cpp_flags += ["-I " + root_path + i]

    for i in _strip_path_prefixes(quote_includes, hdrs_roots):
        c_cpp_flags_short += ["-iquote " + root_path + i]
    for i in _strip_path_prefixes(system_includes, hdrs_roots):
        c_cpp_flags_short += ["-isystem " + root_path + i]
    for i in _strip_path_prefixes(includes, hdrs_roots):
        c_cpp_flags_short += ["-I " + root_path + i]

    # Note that clang has multiple code coverage implementations. covr can only
    # use the gcc compatible implementation based on DebugInfo. This might be
    # different from how your other C++ libraries are being instrumented if you
    # are using an LLVM toolchain.
    # https://cran.r-project.org/web/packages/covr/vignettes/how_it_works.html
    # https://clang.llvm.org/docs/SourceBasedCodeCoverage.html
    if instrumented:
        c_cpp_flags += [
            "--coverage",
            # Ensure that, e.g., functions are not inlined (with optimization,
            # the inlined functions would not be "hit").
            "-O0",
        ]
        c_cpp_flags_short += ["--coverage"]

    instrumented_files = depset()
    if instrumented or instrumented_cc_deps:
        c_libs_flags += ["--coverage", "-O0"]
        c_libs_flags_short += ["--coverage", "-O0"]

    return struct(
        c_cpp_flags = c_cpp_flags,
        c_cpp_flags_short = c_cpp_flags_short,
        c_libs_flags = c_libs_flags,
        c_libs_flags_short = c_libs_flags_short,
        c_so_files = depset(c_so_files).to_list(),
        files = depset(libs, transitive = [hdrs]).to_list(),
        instrumented_files = instrumented_files,
    )

def _remove_file(files, path_to_remove):
    # Removes a file from a given sequence.

    filtered_files = []
    for f in files:
        if f.path != path_to_remove:
            filtered_files.append(f)

    return filtered_files

def _inst_files(inst_files_dict):
    # Lists all files needed to be copied into the inst directory.

    return depset(transitive = [t.files for (t, _) in inst_files_dict.items()])

def _inst_files_copy_map(ctx):
    # Returns a dictionary of destination paths to source paths for copying.

    pkg_src_dir = _package_dir(ctx)

    copy_map = dict()
    for (t, d) in ctx.attr.inst_files.items():
        file_paths = [f.path for f in t.files.to_list()]
        file_roots = [f.root.path for f in t.files.to_list()]
        stripped_paths = _strip_path_prefixes(file_paths, file_roots)
        copy_map.update({
            "%s/inst/%s/%s" % (pkg_src_dir, d, stripped_path): path
            for stripped_path, path in zip(stripped_paths, file_paths)
        })
    return copy_map

def _external_repo(ctx):
    # Returns True if this package is tagged as an external R package.
    return "external-r-repo" in ctx.attr.tags

def _symlink_so_lib(ctx, pkg_name, pkg_lib_dir):
    # Makes an action to output the .so lib file from the R package.

    so_path = "{pkg_lib_dir}/{pkg_name}/libs/{pkg_name}.so".format(
        pkg_lib_dir = pkg_lib_dir.path,
        pkg_name = pkg_name,
    )
    script = """#!/bin/bash
set -euo pipefail
if [[ -f {so_path} ]]; then
  ln -s ./lib/{pkg_name}/libs/{pkg_name}.so {so_lib_out}
else
  touch {so_lib_out}
fi
""".format(pkg_name = pkg_name, so_path = so_path, so_lib_out = ctx.outputs.so_lib.path)
    ctx.actions.run_shell(
        outputs = [ctx.outputs.so_lib],
        inputs = [pkg_lib_dir],
        command = script,
        mnemonic = "RSharedLib",
        use_default_shell_env = False,
        progress_message = "Symlinking .so from R package %s" % pkg_name,
    )

def _stamp_description(ctx, in_tar, out_tar, pkg_name, toolchain_stamp_flag):
    # Makes an action to stamp the DESCRIPTION file in the given archive.

    # This stamp step is separate because bazel remote cache treats volatile
    # status file as part of the action key, and so we want to keep this step
    # as small as possible and as late as possible.

    if not ctx.attr.metadata:
        ctx.actions.symlink(output = out_tar, target_file = in_tar)
        return

    stamp_files = []
    if (ctx.attr.stamp == -1 and toolchain_stamp_flag) or (ctx.attr.stamp == 1):
        # Variables from the volatile status file can not have the prefix STABLE_
        # because those get routed to the stable status file. And there are three
        # special variables that also get routed to the stable status file.
        include_volatile_status_file = False
        include_stable_status_file = False
        for v in ctx.attr.metadata.values():
            stable_vars_count = (_count_group_matches(v, "{STABLE_", "}") +
                                 v.count("{BUILD_EMBED_LABEL}") +
                                 v.count("{BUILD_USER}") +
                                 v.count("{BUILD_HOST}"))
            volatile_vars_count = _count_group_matches(v, "{", "}") - stable_vars_count
            if volatile_vars_count < 0:
                fail("could not parse metadata to deduce volatile and stable status vars")
            if stable_vars_count > 0:
                include_stable_status_file = True
            if volatile_vars_count > 0:
                include_volatile_status_file = True
        if include_volatile_status_file:
            stamp_files.append(ctx.version_file)
        if include_stable_status_file:
            stamp_files.append(ctx.info_file)

    env = {
        "PKG_NAME": pkg_name,
        "IN_TAR": in_tar.path,
        "OUT_TAR": out_tar.path,
        "METADATA_MAP": ",".join([key + ":" + value for (key, value) in ctx.attr.metadata.items()]),
        "STATUS_FILES": ",".join([f.path for f in stamp_files]),
    }

    ctx.actions.run(
        outputs = [out_tar],
        inputs = [in_tar] + stamp_files,
        executable = ctx.executable._stamp_description_sh,
        env = env,
        mnemonic = "RStampDescription",
        use_default_shell_env = False,
        progress_message = "Stamping DESCRIPTION file in R package %s" % pkg_name,
    )

def _merge_tests(ctx, in_tar, out_tar, pkg_name, pkg_src_dir, test_files):
    # Makes an action to merge the given test files into the source archive.

    if not test_files:
        ctx.actions.symlink(output = out_tar, target_file = in_tar)
        return

    env = {
        "PKG_NAME": pkg_name,
        "PKG_SRC_DIR": pkg_src_dir,
        "IN_TAR": in_tar.path,
        "OUT_TAR": out_tar.path,
    }

    ctx.actions.run(
        outputs = [out_tar],
        inputs = [in_tar] + test_files,
        executable = ctx.executable._merge_test_files_sh,
        env = env,
        mnemonic = "RMergeTests",
        use_default_shell_env = False,
        progress_message = "Building R (source) package %s (with tests)" % pkg_name,
    )

def _build_impl(ctx):
    info = ctx.toolchains["@com_grail_rules_r//R:toolchain_type"].RInfo

    pkg_name = _package_name(ctx)
    pkg_src_dir = _package_dir(ctx)
    pkg_lib_dir = ctx.actions.declare_directory("lib")
    pkg_bin_archive = ctx.outputs.bin_archive
    pkg_src_archive = ctx.outputs.src_archive
    flock = ctx.attr._flock.files_to_run.executable

    # Instrumenting external R packages can be troublesome; e.g. RProtoBuf and testthat.
    external_repo = _external_repo(ctx)
    instrumented = (ctx.coverage_instrumented() and
                    not external_repo and
                    not "no-instrument" in ctx.attr.tags)

    pkg_deps = _flatten_pkg_deps_list(ctx.attr.deps)

    src_files_sans_tests = []
    test_files = []
    pkg_tests_dir = _tests_dir(pkg_src_dir)
    for src_file in ctx.files.srcs:
        if src_file.dirname.startswith(pkg_tests_dir):
            test_files.append(src_file)
        else:
            src_files_sans_tests.append(src_file)

    library_deps = _library_deps(pkg_deps)
    cc_deps = _cc_deps(ctx, instrumented)
    inst_files = _inst_files(ctx.attr.inst_files)
    inst_files_map = _inst_files_copy_map(ctx)
    transitive_tools = depset(
        _executables(ctx.attr.tools),
        transitive = [library_deps.transitive_tools],
    )
    build_tools = depset(
        _executables(ctx.attr.build_tools + info.tools),
        transitive = [transitive_tools],
    )
    data = depset(
        transitive = [d[DefaultInfo].files for d in ctx.attr.data],
    )
    instrument_files = [ctx.file._instrument_R] if instrumented else []

    common_input_files = ([ctx.file._build_pkg_common_sh] +
                          library_deps.lib_dirs + cc_deps.files +
                          _makevars_files(info.makevars_site, ctx.file.makevars) +
                          build_tools.to_list() +
                          info.files + [info.state])
    src_input_files = list(common_input_files)
    src_input_files.extend(src_files_sans_tests + inst_files.to_list())

    roclets_lib_dirs = []
    if ctx.attr.roclets:
        roclets_deps = _flatten_pkg_deps_list(ctx.attr.roclets_deps)
        roclets_lib_dirs = _library_deps(roclets_deps).lib_dirs
        src_input_files.extend(roclets_lib_dirs)

    if ctx.file.config_override:
        src_input_files += [ctx.file.config_override]
        orig_config = pkg_src_dir + "/configure"
        src_input_files = _remove_file(src_input_files, orig_config)

    # We first build a source archive with any user-provided inputs, and then
    # use the source archive to build a binary archive.
    # This is better than making a binary archive directly because R performs
    # some standardization (e.g., Authors list in the DESCRIPTION file on macOS)
    # when doing `R CMD build`.

    common_env = {
        "PKG_LIB_PATH": pkg_lib_dir.path,
        "PKG_SRC_DIR": pkg_src_dir,
        "PKG_NAME": pkg_name,
        "R_MAKEVARS_SITE": info.makevars_site.path if info.makevars_site else "",
        "R_MAKEVARS_USER": ctx.file.makevars.path if ctx.file.makevars else "",
        "C_LIBS_FLAGS": " ".join(cc_deps.c_libs_flags),
        "C_CPP_FLAGS": " ".join(cc_deps.c_cpp_flags),
        "C_SO_FILES": _sh_quote_args([f.path for f in cc_deps.c_so_files]),
        "R_LIBS_DEPS": ":".join(["_EXEC_ROOT_" + d.path for d in library_deps.lib_dirs]),
        "EXPORT_ENV_VARS_CMD": "; ".join(_env_vars(info.env_vars) + _env_vars(ctx.attr.env_vars)),
        "BUILD_TOOLS_EXPORT_CMD": _build_path_export(build_tools),
        "FLOCK_PATH": flock.path,
        "INSTRUMENTED": "true" if instrumented else "false",
        "BAZEL_R_DEBUG": "true" if "rlang-debug" in ctx.features else "false",
        "BAZEL_R_VERBOSE": "true" if "rlang-verbose" in ctx.features else "false",
        "R": " ".join(info.r),
        "RSCRIPT": " ".join(info.rscript),
        "REQUIRED_VERSION": info.version,
    }

    pkg_src_archive_stage1 = ctx.actions.declare_file(ctx.attr.name + ".nostamp.notests.tar.gz")
    pkg_src_archive_stage2 = ctx.actions.declare_file(ctx.attr.name + ".notests.tar.gz")
    build_src_env = dict(common_env)
    build_src_env.update({
        "CONFIG_OVERRIDE": ctx.file.config_override.path if ctx.file.config_override else "",
        "PKG_SRC_ARCHIVE": pkg_src_archive_stage1.path,
        "ROCLETS": ", ".join(["'%s'" % r for r in ctx.attr.roclets]),
        "R_LIBS_ROCLETS": ":".join(["_EXEC_ROOT_" + d.path for d in roclets_lib_dirs]),
        "BUILD_ARGS": _sh_quote_args(ctx.attr.build_args),
        "INST_FILES_MAP": ",".join([dst + ":" + src for (dst, src) in inst_files_map.items()]),
    })
    ctx.actions.run(
        outputs = [pkg_src_archive_stage1],
        inputs = src_input_files,
        tools = [flock],
        executable = ctx.executable._build_pkg_src_sh,
        env = build_src_env,
        mnemonic = "RSrcBuild",
        use_default_shell_env = False,
        progress_message = "Building R (source) package %s" % pkg_name,
    )
    _stamp_description(ctx, pkg_src_archive_stage1, pkg_src_archive_stage2, pkg_name, info.stamp)

    bin_input_files = list(common_input_files)
    bin_input_files.extend(instrument_files)
    bin_input_files.append(pkg_src_archive_stage2)

    bin_output_files = [pkg_lib_dir, pkg_bin_archive]
    install_args = list(ctx.attr.install_args)
    pkg_gcno_files = []
    if instrumented:
        # We need to keep the sources for code coverage to work.
        # NOTE: With these options, each installed object in package namespaces gets a
        # srcref attribute that has the source filenames as when installing the package.
        # For reproducible builds, these will be /tmp paths.
        install_args.extend(["--with-keep.source"])

        pkg_srcs_dir = _srcs_dir(pkg_src_dir)
        for src_file in ctx.files.srcs:
            if (not src_file.dirname.startswith(pkg_srcs_dir) or
                not src_file.extension in _NATIVE_SOURCE_EXTS):
                continue
            name = src_file.basename.replace(src_file.extension, "gcno")
            f = ctx.actions.declare_file(name, sibling = src_file)
            pkg_gcno_files.append(f)
        pkg_gcno_files = depset(direct = pkg_gcno_files).to_list()
        bin_output_files.extend(pkg_gcno_files)

    build_bin_env = dict(common_env)
    build_bin_env.update({
        "PKG_BIN_ARCHIVE": pkg_bin_archive.path,
        "PKG_SRC_ARCHIVE": pkg_src_archive_stage2.path,
        "INSTALL_ARGS": _sh_quote_args(install_args),
        "INSTRUMENT_SCRIPT": ctx.file._instrument_R.path,
    })
    ctx.actions.run(
        outputs = bin_output_files,
        inputs = bin_input_files,
        tools = [flock],
        executable = ctx.executable._build_pkg_bin_sh,
        env = build_bin_env,
        mnemonic = "RBuild",
        use_default_shell_env = False,
        progress_message = "Building R package %s" % pkg_name,
    )

    _merge_tests(ctx, pkg_src_archive_stage2, pkg_src_archive, pkg_name, pkg_src_dir, test_files)

    _symlink_so_lib(ctx, pkg_name, pkg_lib_dir)

    instrumented_files_info = coverage_common.instrumented_files_info(
        ctx,
        # List the dependencies in which transitive instrumented files can be found.
        dependency_attributes = ["deps", "cc_deps"],
        # We build instrumented packages with --keep.source, so we don't
        # need the .R files.
        extensions = _NATIVE_SOURCE_EXTS + _NATIVE_HDR_EXTS,
        source_attributes = ["srcs"],
    )

    # Should we include runfiles from cc_deps? Maybe not, because those are
    # supposed to be part of a bazel independent installation. For special
    # cases, we can include the runfiles manually.
    runfiles = ctx.runfiles(
        files = [pkg_lib_dir],
        transitive_files = depset(transitive = [transitive_tools, data]),
    )
    runfiles = runfiles.merge(_runfiles(ctx, ctx.attr.deps + ctx.attr.data + ctx.attr.tools))

    return [
        DefaultInfo(
            files = depset(direct = bin_output_files),
            runfiles = runfiles,
        ),
        RPackage(
            bin_archive = pkg_bin_archive,
            build_tools = build_tools,
            cc_deps = cc_deps,
            external_repo = external_repo,
            makevars = ctx.file.makevars,
            pkg_deps = pkg_deps,
            pkg_gcno_files = pkg_gcno_files,
            pkg_lib_dir = pkg_lib_dir,
            pkg_name = pkg_name,
            src_archive = pkg_src_archive,
            src_files = ctx.files.srcs,
            test_files = test_files,
            transitive_pkg_deps = library_deps.transitive_pkg_deps,
            transitive_tools = transitive_tools,
        ),
        instrumented_files_info,
    ]

def _build_source_pkg_impl(ctx):
    info = ctx.toolchains["@com_grail_rules_r//R:toolchain_type"].RInfo

    pkg_name = _package_name(ctx)
    pkg_src_dir = _package_dir(ctx)
    pkg_lib_dir = ctx.actions.declare_directory("lib")
    pkg_bin_archive = ctx.outputs.bin_archive
    flock = ctx.attr._flock.files_to_run.executable

    # Instrumenting external R packages can be troublesome; e.g. RProtoBuf and testthat.
    external_repo = _external_repo(ctx)
    instrumented = (ctx.coverage_instrumented() and
                    not external_repo and
                    not "no-instrument" in ctx.attr.tags)

    pkg_deps = _flatten_pkg_deps_list(ctx.attr.deps)

    library_deps = _library_deps(pkg_deps)
    cc_deps = _cc_deps(ctx, instrumented)
    transitive_tools = depset(
        _executables(ctx.attr.tools),
        transitive = [library_deps.transitive_tools],
    )
    build_tools = depset(
        _executables(ctx.attr.build_tools + info.tools),
        transitive = [transitive_tools],
    )
    data = depset(
        transitive = [d[DefaultInfo].files for d in ctx.attr.data],
    )
    instrument_files = [ctx.file._instrument_R] if instrumented else []

    input_files = ([ctx.file.src, ctx.file._build_pkg_common_sh, ctx.file._build_pkg_bin_sh] +
                   library_deps.lib_dirs + cc_deps.files +
                   _makevars_files(info.makevars_site, ctx.file.makevars) +
                   build_tools.to_list() +
                   instrument_files +
                   info.files + [info.state])

    if ctx.file.config_override:
        input_files.append(ctx.file.config_override)

    output_files = [pkg_lib_dir, pkg_bin_archive]
    install_args = list(ctx.attr.install_args)
    if instrumented:
        # We need to keep the sources for code coverage to work.
        # NOTE: With these options, each installed object in package namespaces gets a
        # srcref attribute that has the source filenames as when installing the package.
        # For reproducible builds, these will be /tmp paths.
        install_args.extend(["--with-keep.source"])

        # We currently do not instrument native code in source archives.

    env = {
        "DIRECT_FROM_SOURCE": "true",
        "PKG_SRC_DIR": pkg_src_dir,
        "PKG_LIB_PATH": pkg_lib_dir.path,
        "PKG_SRC_ARCHIVE": ctx.file.src.path,
        "PKG_BIN_ARCHIVE": pkg_bin_archive.path,
        "PKG_NAME": pkg_name,
        "R_MAKEVARS_SITE": info.makevars_site.path if info.makevars_site else "",
        "R_MAKEVARS_USER": ctx.file.makevars.path if ctx.file.makevars else "",
        "C_LIBS_FLAGS": " ".join(cc_deps.c_libs_flags),
        "C_CPP_FLAGS": " ".join(cc_deps.c_cpp_flags),
        "C_SO_FILES": _sh_quote_args([f.path for f in cc_deps.c_so_files]),
        "CONFIG_OVERRIDE": ctx.file.config_override.path if ctx.file.config_override else "",
        "R_LIBS_DEPS": ":".join(["_EXEC_ROOT_" + d.path for d in library_deps.lib_dirs]),
        "EXPORT_ENV_VARS_CMD": "; ".join(_env_vars(info.env_vars) + _env_vars(ctx.attr.env_vars)),
        "BUILD_TOOLS_EXPORT_CMD": _build_path_export(build_tools),
        "INSTALL_ARGS": _sh_quote_args(install_args),
        "INSTRUMENT_SCRIPT": ctx.file._instrument_R.path,
        "FLOCK_PATH": flock.path,
        "INSTRUMENTED": "true" if instrumented else "false",
        "BAZEL_R_DEBUG": "true" if "rlang-debug" in ctx.features else "false",
        "BAZEL_R_VERBOSE": "true" if "rlang-verbose" in ctx.features else "false",
        "R": " ".join(info.r),
        "RSCRIPT": " ".join(info.rscript),
        "REQUIRED_VERSION": info.version,
    }
    ctx.actions.run(
        outputs = output_files,
        inputs = input_files,
        tools = [flock],
        executable = ctx.executable._build_pkg_bin_sh,
        env = env,
        mnemonic = "RBuild",
        use_default_shell_env = False,
        progress_message = "Building R package %s" % pkg_name,
    )

    ctx.actions.symlink(output = ctx.outputs.src_archive, target_file = ctx.file.src)

    _symlink_so_lib(ctx, pkg_name, pkg_lib_dir)

    instrumented_files_info = coverage_common.instrumented_files_info(
        ctx,
        # List the dependencies in which transitive instrumented files can be found.
        dependency_attributes = ["deps", "cc_deps"],
        # We build instrumented packages with --keep.source, so we don't
        # need the .R files.
    )

    runfiles = ctx.runfiles(
        files = [pkg_lib_dir],
        transitive_files = depset(transitive = [transitive_tools, data]),
    )
    runfiles = runfiles.merge(_runfiles(ctx, ctx.attr.deps + ctx.attr.data + ctx.attr.tools))

    return [
        DefaultInfo(
            files = depset([pkg_lib_dir]),
            runfiles = runfiles,
        ),
        RPackage(
            bin_archive = pkg_bin_archive,
            build_tools = build_tools,
            cc_deps = cc_deps,
            external_repo = external_repo,
            makevars = ctx.file.makevars,
            pkg_deps = pkg_deps,
            pkg_gcno_files = None,
            pkg_lib_dir = pkg_lib_dir,
            pkg_name = pkg_name,
            src_archive = ctx.file.src,
            src_files = None,
            test_files = None,
            transitive_pkg_deps = library_deps.transitive_pkg_deps,
            transitive_tools = transitive_tools,
        ),
        instrumented_files_info,
    ]

def _build_binary_pkg_impl(ctx):
    info = ctx.toolchains["@com_grail_rules_r//R:toolchain_type"].RInfo

    pkg_name = _package_name(ctx)
    pkg_lib_dir = ctx.actions.declare_directory("lib")
    pkg_bin_archive = ctx.file.src
    pkg_deps = _flatten_pkg_deps_list(ctx.attr.deps)
    library_deps = _library_deps(pkg_deps)
    transitive_tools = depset(
        _executables(ctx.attr.tools),
        transitive = [library_deps.transitive_tools],
    )
    build_tools = _executables(info.tools)
    data = depset(
        transitive = [d[DefaultInfo].files for d in ctx.attr.data],
    )

    build_env = {
        "PKG_LIB_PATH": pkg_lib_dir.path,
        "PKG_NAME": pkg_name,
        "PKG_BIN_ARCHIVE": pkg_bin_archive.path,
        "R_LIBS_DEPS": ":".join(["_EXEC_ROOT_" + d.path for d in library_deps.lib_dirs]),
        "INSTALL_ARGS": _sh_quote_args(ctx.attr.install_args),
        "EXPORT_ENV_VARS_CMD": "; ".join(_env_vars(ctx.attr.env_vars)),
        "BUILD_TOOLS_EXPORT_CMD": _build_path_export(depset(build_tools)),
        "BAZEL_R_DEBUG": "true" if "rlang-debug" in ctx.features else "false",
        "BAZEL_R_VERBOSE": "true" if "rlang-verbose" in ctx.features else "false",
        "R": " ".join(info.r),
        "RSCRIPT": " ".join(info.rscript),
        "REQUIRED_VERSION": info.version,
    }
    ctx.actions.run(
        outputs = [pkg_lib_dir],
        inputs = [pkg_bin_archive, info.state] + build_tools,
        executable = ctx.executable._build_binary_sh,
        env = build_env,
        mnemonic = "RBuildBinary",
        use_default_shell_env = False,
        progress_message = "Extracting R binary package %s" % pkg_name,
    )

    ctx.actions.symlink(output = ctx.outputs.bin_archive, target_file = pkg_bin_archive)

    _symlink_so_lib(ctx, pkg_name, pkg_lib_dir)

    runfiles = ctx.runfiles(
        files = [pkg_lib_dir],
        transitive_files = depset(transitive = [transitive_tools, data]),
    )
    runfiles = runfiles.merge(_runfiles(ctx, ctx.attr.deps + ctx.attr.data + ctx.attr.tools))

    return [
        DefaultInfo(
            files = depset([pkg_lib_dir]),
            runfiles = runfiles,
        ),
        RPackage(
            bin_archive = pkg_bin_archive,
            build_tools = None,
            cc_deps = None,
            external_repo = _external_repo(ctx),
            makevars = None,
            pkg_deps = pkg_deps,
            pkg_gcno_files = None,
            pkg_lib_dir = pkg_lib_dir,
            pkg_name = pkg_name,
            src_archive = None,
            src_files = None,
            transitive_pkg_deps = library_deps.transitive_pkg_deps,
            transitive_tools = transitive_tools,
        ),
        coverage_common.instrumented_files_info(ctx),
    ]

_COMMON_ATTRS = {
    "pkg_name": attr.string(
        doc = "Name of the package if different from the target name",
    ),
    "deps": attr.label_list(
        providers = [
            [RPackage],
            [RLibrary],
        ],
        doc = "R package dependencies of type r_pkg or r_library",
    ),
    "data": attr.label_list(
        allow_files = True,
        doc = "Runtime dependencies for the package, when running under bazel",
    ),
    "tools": attr.label_list(
        allow_files = True,
        doc = "Executables that code in this package will try to find in the system",
    ),
    "install_args": attr.string_list(
        doc = "Additional arguments to supply to R CMD INSTALL",
    ),
    "env_vars": attr.string_dict(
        doc = "Extra environment variables to define for building the package",
    ),
}

# Attributes for both `R CMD build` and `R CMD INSTALL`.
_COMMON_BUILD_ATTRS = {
    "cc_deps": attr.label_list(
        doc = "cc_library dependencies for this package",
    ),
    "config_override": attr.label(
        allow_single_file = True,
        doc = "Replace the package configure script with this file",
    ),
    "makevars": attr.label(
        allow_single_file = True,
        doc = "Additional Makevars file supplied as R_MAKEVARS_USER",
    ),
    "build_tools": attr.label_list(
        allow_files = True,
        doc = "Executables that package build and load will try to find in the system",
    ),
    "_build_pkg_common_sh": attr.label(
        allow_single_file = True,
        default = "@com_grail_rules_r//R/scripts:build_pkg_common.sh",
    ),
    "_build_pkg_bin_sh": attr.label(
        allow_single_file = True,
        default = "@com_grail_rules_r//R/scripts:build_pkg_bin.sh",
        executable = True,
        cfg = "host",
    ),
    "_flock": attr.label(
        default = "@com_grail_rules_r//R/scripts:flock",
        executable = True,
        cfg = "host",
    ),
    "_instrument_R": attr.label(
        allow_single_file = True,
        default = "@com_grail_rules_r//R/scripts:instrument.R",
    ),
}

# Attributes for `R CMD build`.
_BUILD_ATTRS = {
    "srcs": attr.label_list(
        allow_files = True,
        mandatory = True,
        doc = "Source files to be included for building the package",
    ),
    "build_args": attr.string_list(
        default = [
            "--no-build-vignettes",
            "--no-manual",
        ],
        doc = "Additional arguments to supply to R CMD build",
    ),
    "roclets": attr.string_list(
        doc = ("roclets to run before installing the package. If this is non-empty, " +
               "then you must specify roclets_deps as the R package you want to " +
               "use for running roclets. The runtime code will check if devtools " +
               "is available and use `devtools::document`, failing which, it will " +
               "check if roxygen2 is available and use `roxygen2::roxygenize`"),
    ),
    "roclets_deps": attr.label_list(
        providers = [
            [RPackage],
            [RLibrary],
        ],
        doc = "roxygen2 or devtools dependency for running roclets",
    ),
    "inst_files": attr.label_keyed_string_dict(
        allow_files = True,
        cfg = "target",
        doc = "Files to be bundled with the package through the inst directory. " +
              "The values of the dictionary will specify the package relative " +
              "destination path. For example, '' will bundle the files to the top level " +
              "directory, and 'mydir' will bundle all files into a directory mydir.",
    ),
    "metadata": attr.string_dict(
        doc = ("Metadata key-value pairs to add to the DESCRIPTION file before building. " +
               "When text is enclosed within `{}`, bazel volatile and stable status " +
               "files will be used to substitute the text. Inclusion of these files in " +
               "the build has consequences on local and remote caching. Also see `stamp`."),
    ),
    "stamp": attr.int(
        default = -1,
        doc = "Same behavior as the stamp attribute in cc_binary rule.",
    ),
    "_build_pkg_src_sh": attr.label(
        allow_single_file = True,
        default = "@com_grail_rules_r//R/scripts:build_pkg_src.sh",
        executable = True,
        cfg = "host",
    ),
    "_merge_test_files_sh": attr.label(
        allow_single_file = True,
        default = "@com_grail_rules_r//R/scripts:merge_test_files.sh",
        executable = True,
        cfg = "host",
    ),
    "_stamp_description_sh": attr.label(
        allow_single_file = True,
        default = "@com_grail_rules_r//R/scripts:stamp_description.sh",
        executable = True,
        cfg = "host",
    ),
}

_PKG_ATTRS = dict(_COMMON_ATTRS)
_PKG_ATTRS.update(_COMMON_BUILD_ATTRS)
_PKG_ATTRS.update(_BUILD_ATTRS)

_SOURCE_PKG_ATTRS = dict(_COMMON_ATTRS)
_SOURCE_PKG_ATTRS.update(_COMMON_BUILD_ATTRS)
_SOURCE_PKG_ATTRS.update({
    "src": attr.label(
        allow_single_file = True,
        mandatory = True,
        doc = "Source archive of the package",
    ),
})

_BINARY_PKG_ATTRS = dict(_COMMON_ATTRS)
_BINARY_PKG_ATTRS.update({
    "src": attr.label(
        allow_single_file = True,
        mandatory = True,
        doc = "Binary archive of the package",
    ),
    "_build_binary_sh": attr.label(
        allow_single_file = True,
        default = "@com_grail_rules_r//R/scripts:build_binary.sh",
        executable = True,
        cfg = "host",
    ),
})

r_pkg = rule(
    attrs = _PKG_ATTRS,
    doc = ("Rule to install the package and its transitive dependencies " +
           "in the Bazel sandbox."),
    outputs = {
        "bin_archive": "%{name}.bin.tar.gz",
        "src_archive": "%{name}.tar.gz",
        "so_lib": "%{name}.so",
    },
    toolchains = ["@com_grail_rules_r//R:toolchain_type"],
    implementation = _build_impl,
)

r_source_pkg = rule(
    attrs = _SOURCE_PKG_ATTRS,
    doc = ("Rule to install the package and its transitive dependencies in " +
           "the Bazel sandbox from a source archive."),
    outputs = {
        "bin_archive": "%{name}.bin.tar.gz",
        "src_archive": "%{name}.tar.gz",
        "so_lib": "%{name}.so",
    },
    toolchains = ["@com_grail_rules_r//R:toolchain_type"],
    implementation = _build_source_pkg_impl,
)

r_binary_pkg = rule(
    attrs = _BINARY_PKG_ATTRS,
    doc = ("Rule to install the package and its transitive dependencies in " +
           "the Bazel sandbox from a binary archive."),
    outputs = {
        "bin_archive": "%{name}.bin.tar.gz",
        "so_lib": "%{name}.so",
    },
    toolchains = ["@com_grail_rules_r//R:toolchain_type"],
    implementation = _build_binary_pkg_impl,
)
