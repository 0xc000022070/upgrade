#![allow(non_camel_case_types, dead_code)]

use std::ffi::{c_int, c_void};

pub type GhosttyResult = c_int;
pub const SUCCESS: GhosttyResult = 0;
pub const NO_VALUE: GhosttyResult = -4;

#[repr(C)]
pub struct GhosttyAllocator {
    _opaque: [u8; 0],
}

#[repr(C)]
pub struct TerminalImpl {
    _opaque: [u8; 0],
}
pub type GhosttyTerminal = *mut TerminalImpl;

#[repr(C)]
pub struct KittyGraphicsImpl {
    _opaque: [u8; 0],
}
pub type GhosttyKittyGraphics = *mut KittyGraphicsImpl;

#[repr(C)]
pub struct KittyImageImpl {
    _opaque: [u8; 0],
}
pub type GhosttyKittyGraphicsImage = *const KittyImageImpl;

#[repr(C)]
pub struct PlacementIteratorImpl {
    _opaque: [u8; 0],
}
pub type GhosttyKittyGraphicsPlacementIterator = *mut PlacementIteratorImpl;

pub const OPT_KITTY_IMAGE_STORAGE_LIMIT: c_int = 15;
pub const OPT_SCROLLBACK_MAX_BYTES: c_int = 27;
pub const OPT_SCROLLBACK_MAX_LINES: c_int = 28;
pub const OPT_CONTINUATION_MAX_BYTES: c_int = 31;

pub const DATA_CURSOR_X: c_int = 3;
pub const DATA_CURSOR_Y: c_int = 4;
pub const DATA_KITTY_GRAPHICS: c_int = 30;
pub const DATA_MODE: c_int = 37;
pub const DATA_VT_GROUND: c_int = 38;

pub const MODE_ORIGIN: u16 = 6;

pub const KITTY_DATA_PLACEMENT_ITERATOR: c_int = 1;

pub const PLACEMENT_IMAGE_ID: c_int = 1;
pub const PLACEMENT_PLACEMENT_ID: c_int = 2;
pub const PLACEMENT_IS_VIRTUAL: c_int = 3;
pub const PLACEMENT_X_OFFSET: c_int = 4;
pub const PLACEMENT_Y_OFFSET: c_int = 5;
pub const PLACEMENT_SOURCE_X: c_int = 6;
pub const PLACEMENT_SOURCE_Y: c_int = 7;
pub const PLACEMENT_SOURCE_WIDTH: c_int = 8;
pub const PLACEMENT_SOURCE_HEIGHT: c_int = 9;
pub const PLACEMENT_COLUMNS: c_int = 10;
pub const PLACEMENT_ROWS: c_int = 11;
pub const PLACEMENT_Z: c_int = 12;

pub const IMAGE_WIDTH: c_int = 3;
pub const IMAGE_HEIGHT: c_int = 4;
pub const IMAGE_FORMAT: c_int = 5;
pub const IMAGE_DATA_PTR: c_int = 7;
pub const IMAGE_DATA_LEN: c_int = 8;

pub const FORMAT_RGB: c_int = 0;
pub const FORMAT_RGBA: c_int = 1;
pub const FORMAT_PNG: c_int = 2;
pub const FORMAT_GRAY_ALPHA: c_int = 3;
pub const FORMAT_GRAY: c_int = 4;

pub const SYS_OPT_DECODE_PNG: c_int = 1;

#[repr(C)]
pub struct GhosttyTerminalModeConfig {
    pub mode: u16,
    pub value: bool,
}

#[repr(C)]
#[derive(Default)]
pub struct GhosttyKittyGraphicsPlacementRenderInfo {
    pub size: usize,
    pub pixel_width: u32,
    pub pixel_height: u32,
    pub grid_cols: u32,
    pub grid_rows: u32,
    pub viewport_col: i32,
    pub viewport_row: i32,
    pub viewport_visible: bool,
    pub source_x: u32,
    pub source_y: u32,
    pub source_width: u32,
    pub source_height: u32,
}

#[repr(C)]
pub struct GhosttySysImage {
    pub width: u32,
    pub height: u32,
    pub data: *mut u8,
    pub data_len: usize,
}

pub type GhosttySysDecodePngFn = unsafe extern "C" fn(
    userdata: *mut c_void,
    allocator: *const GhosttyAllocator,
    data: *const u8,
    data_len: usize,
    out: *mut GhosttySysImage,
) -> bool;

extern "C" {
    pub fn ghostty_alloc(allocator: *const GhosttyAllocator, len: usize) -> *mut u8;
    pub fn ghostty_free(allocator: *const GhosttyAllocator, ptr: *mut u8, len: usize);

    pub fn ghostty_sys_set(option: c_int, value: *const c_void) -> GhosttyResult;

    pub fn ghostty_terminal_new(
        allocator: *const GhosttyAllocator,
        terminal: *mut GhosttyTerminal,
        cols: u16,
        rows: u16,
    ) -> GhosttyResult;
    pub fn ghostty_terminal_free(terminal: GhosttyTerminal);
    pub fn ghostty_terminal_resize(
        terminal: GhosttyTerminal,
        cols: u16,
        rows: u16,
        cell_width_px: u32,
        cell_height_px: u32,
    ) -> GhosttyResult;
    pub fn ghostty_terminal_set(
        terminal: GhosttyTerminal,
        option: c_int,
        value: *const c_void,
    ) -> GhosttyResult;
    pub fn ghostty_terminal_vt_write(terminal: GhosttyTerminal, data: *const u8, len: usize);
    pub fn ghostty_terminal_get(
        terminal: GhosttyTerminal,
        data: c_int,
        out: *mut c_void,
    ) -> GhosttyResult;

    pub fn ghostty_snapshot_encode_alloc(
        terminal: GhosttyTerminal,
        allocator: *const GhosttyAllocator,
        out_ptr: *mut *mut u8,
        out_len: *mut usize,
    ) -> GhosttyResult;

    pub fn ghostty_kitty_graphics_get(
        graphics: GhosttyKittyGraphics,
        data: c_int,
        out: *mut c_void,
    ) -> GhosttyResult;
    pub fn ghostty_kitty_graphics_image(
        graphics: GhosttyKittyGraphics,
        image_id: u32,
    ) -> GhosttyKittyGraphicsImage;
    pub fn ghostty_kitty_graphics_image_get(
        image: GhosttyKittyGraphicsImage,
        data: c_int,
        out: *mut c_void,
    ) -> GhosttyResult;
    pub fn ghostty_kitty_graphics_placement_iterator_new(
        allocator: *const GhosttyAllocator,
        out_iterator: *mut GhosttyKittyGraphicsPlacementIterator,
    ) -> GhosttyResult;
    pub fn ghostty_kitty_graphics_placement_iterator_free(
        iterator: GhosttyKittyGraphicsPlacementIterator,
    );
    pub fn ghostty_kitty_graphics_placement_next(
        iterator: GhosttyKittyGraphicsPlacementIterator,
    ) -> bool;
    pub fn ghostty_kitty_graphics_placement_get(
        iterator: GhosttyKittyGraphicsPlacementIterator,
        data: c_int,
        out: *mut c_void,
    ) -> GhosttyResult;
    pub fn ghostty_kitty_graphics_placement_render_info(
        iterator: GhosttyKittyGraphicsPlacementIterator,
        image: GhosttyKittyGraphicsImage,
        terminal: GhosttyTerminal,
        out_info: *mut GhosttyKittyGraphicsPlacementRenderInfo,
    ) -> GhosttyResult;
}
