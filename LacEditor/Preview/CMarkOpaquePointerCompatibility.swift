import cmark_gfm
import cmark_gfm_extensions

// swift-cmark 0.8 exposes cmark_node as a typed C pointer. The editor keeps
// node identities as OpaquePointer, so conversions stay at this API boundary.
@inline(__always) func cmark_node_get_type(_ node: OpaquePointer) -> cmark_node_type { cmark_node_get_type(UnsafeMutablePointer<cmark_node>(node)) }
@inline(__always) func cmark_node_get_type_string(_ node: OpaquePointer) -> UnsafePointer<CChar>? { cmark_node_get_type_string(UnsafeMutablePointer<cmark_node>(node)) }
@inline(__always) func cmark_node_get_literal(_ node: OpaquePointer) -> UnsafePointer<CChar>? { cmark_node_get_literal(UnsafeMutablePointer<cmark_node>(node)) }
@inline(__always) func cmark_node_get_url(_ node: OpaquePointer) -> UnsafePointer<CChar>? { cmark_node_get_url(UnsafeMutablePointer<cmark_node>(node)) }
@inline(__always) func cmark_node_get_title(_ node: OpaquePointer) -> UnsafePointer<CChar>? { cmark_node_get_title(UnsafeMutablePointer<cmark_node>(node)) }
@inline(__always) func cmark_node_get_fence_info(_ node: OpaquePointer) -> UnsafePointer<CChar>? { cmark_node_get_fence_info(UnsafeMutablePointer<cmark_node>(node)) }
@inline(__always) func cmark_node_set_literal(_ node: OpaquePointer, _ content: UnsafePointer<CChar>) -> Int32 { cmark_node_set_literal(UnsafeMutablePointer<cmark_node>(node), content) }
@inline(__always) func cmark_node_set_string_content(_ node: OpaquePointer, _ content: UnsafePointer<CChar>) -> Int32 { cmark_node_set_string_content(UnsafeMutablePointer<cmark_node>(node), content) }
@inline(__always) func cmark_node_next(_ node: OpaquePointer) -> OpaquePointer? { cmark_node_next(UnsafeMutablePointer<cmark_node>(node)).map(OpaquePointer.init) }
@inline(__always) func cmark_node_previous(_ node: OpaquePointer) -> OpaquePointer? { cmark_node_previous(UnsafeMutablePointer<cmark_node>(node)).map(OpaquePointer.init) }
@inline(__always) func cmark_node_parent(_ node: OpaquePointer) -> OpaquePointer? { cmark_node_parent(UnsafeMutablePointer<cmark_node>(node)).map(OpaquePointer.init) }
@inline(__always) func cmark_node_first_child(_ node: OpaquePointer) -> OpaquePointer? { cmark_node_first_child(UnsafeMutablePointer<cmark_node>(node)).map(OpaquePointer.init) }
@inline(__always) func cmark_node_last_child(_ node: OpaquePointer) -> OpaquePointer? { cmark_node_last_child(UnsafeMutablePointer<cmark_node>(node)).map(OpaquePointer.init) }
@inline(__always) func cmark_node_parent_footnote_def(_ node: OpaquePointer) -> OpaquePointer? { cmark_node_parent_footnote_def(UnsafeMutablePointer<cmark_node>(node)).map(OpaquePointer.init) }
@inline(__always) func cmark_node_get_start_line(_ node: OpaquePointer) -> Int32 { cmark_node_get_start_line(UnsafeMutablePointer<cmark_node>(node)) }
@inline(__always) func cmark_node_get_start_column(_ node: OpaquePointer) -> Int32 { cmark_node_get_start_column(UnsafeMutablePointer<cmark_node>(node)) }
@inline(__always) func cmark_node_get_end_line(_ node: OpaquePointer) -> Int32 { cmark_node_get_end_line(UnsafeMutablePointer<cmark_node>(node)) }
@inline(__always) func cmark_node_get_end_column(_ node: OpaquePointer) -> Int32 { cmark_node_get_end_column(UnsafeMutablePointer<cmark_node>(node)) }
@inline(__always) func cmark_node_get_heading_level(_ node: OpaquePointer) -> Int32 { cmark_node_get_heading_level(UnsafeMutablePointer<cmark_node>(node)) }
@inline(__always) func cmark_node_get_list_type(_ node: OpaquePointer) -> cmark_list_type { cmark_node_get_list_type(UnsafeMutablePointer<cmark_node>(node)) }
@inline(__always) func cmark_node_get_list_delim(_ node: OpaquePointer) -> cmark_delim_type { cmark_node_get_list_delim(UnsafeMutablePointer<cmark_node>(node)) }
@inline(__always) func cmark_node_get_list_start(_ node: OpaquePointer) -> Int32 { cmark_node_get_list_start(UnsafeMutablePointer<cmark_node>(node)) }
@inline(__always) func cmark_node_get_list_tight(_ node: OpaquePointer) -> Int32 { cmark_node_get_list_tight(UnsafeMutablePointer<cmark_node>(node)) }
@inline(__always) func cmark_node_set_list_tight(_ node: OpaquePointer, _ tight: Int32) -> Int32 { cmark_node_set_list_tight(UnsafeMutablePointer<cmark_node>(node), tight) }
@inline(__always) func cmark_node_get_syntax_extension(_ node: OpaquePointer) -> OpaquePointer? { cmark_node_get_syntax_extension(UnsafeMutablePointer<cmark_node>(node)).map(OpaquePointer.init) }
@inline(__always) func cmark_node_unlink(_ node: OpaquePointer) { cmark_node_unlink(UnsafeMutablePointer<cmark_node>(node)) }
@inline(__always) func cmark_node_free(_ node: OpaquePointer) { cmark_node_free(UnsafeMutablePointer<cmark_node>(node)) }
@inline(__always) func cmark_node_prepend_child(_ node: OpaquePointer, _ child: UnsafeMutablePointer<cmark_node>) -> Int32 { cmark_node_prepend_child(UnsafeMutablePointer<cmark_node>(node), child) }
@inline(__always) func cmark_node_append_child(_ node: OpaquePointer, _ child: UnsafeMutablePointer<cmark_node>) -> Int32 { cmark_node_append_child(UnsafeMutablePointer<cmark_node>(node), child) }
@inline(__always) func cmark_node_append_child(_ node: UnsafeMutablePointer<cmark_node>, _ child: OpaquePointer) -> Int32 { cmark_node_append_child(node, UnsafeMutablePointer<cmark_node>(child)) }
@inline(__always) func cmark_node_append_child(_ node: OpaquePointer, _ child: OpaquePointer) -> Int32 { cmark_node_append_child(UnsafeMutablePointer<cmark_node>(node), UnsafeMutablePointer<cmark_node>(child)) }
@inline(__always) func cmark_node_insert_before(_ node: OpaquePointer, _ sibling: UnsafeMutablePointer<cmark_node>) -> Int32 { cmark_node_insert_before(UnsafeMutablePointer<cmark_node>(node), sibling) }
@inline(__always) func cmark_node_insert_before(_ node: UnsafeMutablePointer<cmark_node>, _ sibling: OpaquePointer) -> Int32 { cmark_node_insert_before(node, UnsafeMutablePointer<cmark_node>(sibling)) }
@inline(__always) func cmark_node_insert_before(_ node: OpaquePointer, _ sibling: OpaquePointer) -> Int32 { cmark_node_insert_before(UnsafeMutablePointer<cmark_node>(node), UnsafeMutablePointer<cmark_node>(sibling)) }
@inline(__always) func cmark_node_replace(_ oldNode: OpaquePointer, _ newNode: UnsafeMutablePointer<cmark_node>) -> Int32 { cmark_node_replace(UnsafeMutablePointer<cmark_node>(oldNode), newNode) }
@inline(__always) func cmark_node_replace(_ oldNode: UnsafeMutablePointer<cmark_node>, _ newNode: OpaquePointer) -> Int32 { cmark_node_replace(oldNode, UnsafeMutablePointer<cmark_node>(newNode)) }
@inline(__always) func cmark_node_replace(_ oldNode: OpaquePointer, _ newNode: OpaquePointer) -> Int32 { cmark_node_replace(UnsafeMutablePointer<cmark_node>(oldNode), UnsafeMutablePointer<cmark_node>(newNode)) }
@inline(__always) func cmark_node_set_url(_ node: OpaquePointer, _ url: UnsafePointer<CChar>) -> Int32 { cmark_node_set_url(UnsafeMutablePointer<cmark_node>(node), url) }
@inline(__always) func cmark_node_insert_after(_ node: OpaquePointer, _ sibling: OpaquePointer) -> Int32 { cmark_node_insert_after(UnsafeMutablePointer<cmark_node>(node), UnsafeMutablePointer<cmark_node>(sibling)) }
@inline(__always) func cmark_node_insert_after(_ node: OpaquePointer, _ sibling: UnsafeMutablePointer<cmark_node>) -> Int32 { cmark_node_insert_after(UnsafeMutablePointer<cmark_node>(node), sibling) }
@inline(__always) func cmark_node_get_string_content(_ node: OpaquePointer) -> UnsafePointer<CChar>? { cmark_node_get_string_content(UnsafeMutablePointer<cmark_node>(node)) }
@inline(__always) func cmark_gfm_extensions_get_tasklist_item_checked(_ node: OpaquePointer) -> Bool { cmark_gfm_extensions_get_tasklist_item_checked(UnsafeMutablePointer<cmark_node>(node)) }
@inline(__always) func cmark_gfm_extensions_get_table_columns(_ node: OpaquePointer) -> UInt16 { cmark_gfm_extensions_get_table_columns(UnsafeMutablePointer<cmark_node>(node)) }
@inline(__always) func cmark_gfm_extensions_get_table_alignments(_ node: OpaquePointer) -> UnsafeMutablePointer<UInt8>? { cmark_gfm_extensions_get_table_alignments(UnsafeMutablePointer<cmark_node>(node)) }
@inline(__always) func cmark_syntax_extension_get_private(_ extensionPointer: OpaquePointer) -> UnsafeMutableRawPointer? { cmark_syntax_extension_get_private(UnsafeMutablePointer<cmark_syntax_extension>(extensionPointer)) }
@inline(__always) func cmark_render_html(_ root: OpaquePointer, _ options: Int32, _ extensions: UnsafeMutablePointer<cmark_llist>?) -> UnsafeMutablePointer<CChar>? { cmark_render_html(UnsafeMutablePointer<cmark_node>(root), options, extensions) }
@inline(__always) func cmark_parser_get_syntax_extensions(_ parser: OpaquePointer) -> UnsafeMutablePointer<cmark_llist>? { cmark_parser_get_syntax_extensions(UnsafeMutablePointer<cmark_parser>(parser)) }
