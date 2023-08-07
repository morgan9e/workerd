load("@capnp-cpp//src/capnp:cc_capnp_library.bzl", "cc_capnp_library")
load("@bazel_skylib//rules:copy_file.bzl", "copy_file")

CAPNP_TEMPLATE = """@{schema_id};

# generated by @workerd//build/wd_js_bundle.bzl

using Modules = import "/workerd/jsg/modules.capnp";

const {const_name} :Modules.Bundle = (
  modules = [
{modules}
]);
"""

MODULE_TEMPLATE = """    (name = "{name}", src = embed "{path}", type = {type}, {ts_declaration})"""

def _to_d_ts(file_name):
    return file_name.removesuffix(".js") + ".d.ts"

def _relative_path(file_path, dir_path):
    if not file_path.startswith(dir_path):
        fail("file_path need to start with dir_path: " + file_path + " vs " + dir_path)
    return file_path.removeprefix(dir_path)

def _gen_api_bundle_capnpn_impl(ctx):
    output_dir = ctx.outputs.out.dirname + "/"

    def _render_module(name, label, type):
        return MODULE_TEMPLATE.format(
            name = name,
            # capnp doesn't allow ".." dir escape, make paths relative.
            # this won't work for embedding paths outside of rule directory subtree.
            path = _relative_path(
                ctx.expand_location("$(location {})".format(label), ctx.attr.data),
                output_dir,
            ),
            ts_declaration = (
                "tsDeclaration = embed \"" + _relative_path(
                    ctx.expand_location("$(location {})".format(ctx.attr.declarations[name]), ctx.attr.data),
                    output_dir,
                ) + "\", "
            ) if name in ctx.attr.declarations else "",
            type = type,
        )

    modules = [
        _render_module(ctx.attr.builtin_modules[m], m.label, "builtin")
        for m in ctx.attr.builtin_modules
    ]
    modules += [
        _render_module(ctx.attr.internal_modules[m], m.label, "internal")
        for m in ctx.attr.internal_modules
    ]

    content = CAPNP_TEMPLATE.format(
        schema_id = ctx.attr.schema_id,
        modules = ",\n".join(modules),
        const_name = ctx.attr.const_name,
    )
    ctx.actions.write(ctx.outputs.out, content)

gen_api_bundle_capnpn = rule(
    implementation = _gen_api_bundle_capnpn_impl,
    attrs = {
        "schema_id": attr.string(mandatory = True),
        "out": attr.output(mandatory = True),
        "builtin_modules": attr.label_keyed_string_dict(allow_files = True),
        "internal_modules": attr.label_keyed_string_dict(allow_files = True),
        "declarations": attr.string_dict(),
        "data": attr.label_list(allow_files = True),
        "const_name": attr.string(mandatory = True),
    },
)

def _copy_modules(modules, declarations):
    """Copy files from the modules map to the current package.

    Returns new module map using file copies.
    This is necessary since capnp compiler doesn't allow embeds outside of current subidrectory.
    """
    result = dict()
    declarations_result = dict()
    for m in modules:
        new_filename = modules[m].replace(":", "_").replace("/", "_")
        copy_file(name = new_filename + "@copy", src = m, out = new_filename)

        m_d_ts = _to_d_ts(m)
        if m_d_ts in declarations:
            new_d_ts_filename = new_filename + ".d.ts"
            copy_file(name = new_d_ts_filename + "@copy", src = m_d_ts, out = new_d_ts_filename)
            declarations_result[modules[m]] = str(native.package_relative_label(new_d_ts_filename))

        result[new_filename] = modules[m]
    return result, declarations_result

def wd_js_bundle(
        name,
        schema_id,
        const_name,
        builtin_modules = {},
        internal_modules = {},
        declarations = [],
        **kwargs):
    """Generate cc capnp library with js api bundle.

    NOTE: Due to capnpc embed limitation all modules must be in the same or sub directory of the
          actual rule usage.

    Args:
     name: cc_capnp_library rule name
     builtin_modules: js src label -> module name dictionary
     internal_modules: js src label -> module name dictionary
     declarations: d.ts label set
     const_name: capnp constant name that will contain bundle definition
     schema_id: capnpn schema id
     **kwargs: rest of cc_capnp_library arguments
    """

    builtin_modules, builtin_declarations = _copy_modules(builtin_modules, declarations)
    internal_modules, internal_declarations = _copy_modules(internal_modules, declarations)

    data = list(builtin_modules) + list(internal_modules) + list(builtin_declarations.values()) + list(internal_declarations.values())

    gen_api_bundle_capnpn(
        name = name + "@gen",
        out = name + ".capnp",
        schema_id = schema_id,
        const_name = const_name,
        builtin_modules = builtin_modules,
        internal_modules = internal_modules,
        declarations = builtin_declarations | internal_declarations,
        data = data,
    )

    cc_capnp_library(
        name = name,
        srcs = [name + ".capnp"],
        strip_include_prefix = "",
        visibility = ["//visibility:public"],
        data = data,
        deps = ["@workerd//src/workerd/jsg:modules_capnp"],
        **kwargs
    )