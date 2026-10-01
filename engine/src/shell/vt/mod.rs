mod ffi;

use super::kitty;
use super::wire::Size;
use std::ffi::c_void;
use std::fmt;
use std::sync::Once;

#[derive(Debug)]
pub struct VtError(&'static str, ffi::GhosttyResult);

impl fmt::Display for VtError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "libghostty-vt {} failed with {}", self.0, self.1)
    }
}

fn check(call: &'static str, result: ffi::GhosttyResult) -> Result<(), VtError> {
    if result == ffi::SUCCESS {
        Ok(())
    } else {
        Err(VtError(call, result))
    }
}

pub struct Options {
    pub scrollback_lines: usize,
    pub scrollback_bytes: usize,
    pub image_bytes: u64,
}

const CONTINUATION_BYTES: usize = 1 << 20;

pub struct Terminal {
    raw: ffi::GhosttyTerminal,
}

impl Drop for Terminal {
    fn drop(&mut self) {
        unsafe { ffi::ghostty_terminal_free(self.raw) };
    }
}

impl Terminal {
    pub fn new(size: Size, options: &Options) -> Result<Self, VtError> {
        install_png_decoder();
        let mut raw: ffi::GhosttyTerminal = std::ptr::null_mut();
        check("terminal_new", unsafe {
            ffi::ghostty_terminal_new(
                std::ptr::null(),
                &mut raw,
                size.cols.max(1),
                size.rows.max(1),
            )
        })?;
        let terminal = Self { raw };
        terminal.set(ffi::OPT_SCROLLBACK_MAX_LINES, &options.scrollback_lines)?;
        terminal.set(ffi::OPT_SCROLLBACK_MAX_BYTES, &options.scrollback_bytes)?;
        terminal.set(ffi::OPT_KITTY_IMAGE_STORAGE_LIMIT, &options.image_bytes)?;
        terminal.set(ffi::OPT_CONTINUATION_MAX_BYTES, &CONTINUATION_BYTES)?;
        let mut terminal = terminal;
        terminal.resize(size)?;
        Ok(terminal)
    }

    fn set<T>(&self, option: std::ffi::c_int, value: &T) -> Result<(), VtError> {
        check("terminal_set", unsafe {
            ffi::ghostty_terminal_set(self.raw, option, value as *const T as *const c_void)
        })
    }

    fn get<T: Default>(&self, data: std::ffi::c_int) -> Option<T> {
        let mut out = T::default();
        let result =
            unsafe { ffi::ghostty_terminal_get(self.raw, data, &mut out as *mut T as *mut c_void) };
        (result == ffi::SUCCESS).then_some(out)
    }

    pub fn write(&mut self, bytes: &[u8]) {
        unsafe { ffi::ghostty_terminal_vt_write(self.raw, bytes.as_ptr(), bytes.len()) };
    }

    pub fn resize(&mut self, size: Size) -> Result<(), VtError> {
        let cols = size.cols.max(1);
        let rows = size.rows.max(1);
        let cell_width = u32::from(size.width_px) / u32::from(cols);
        let cell_height = u32::from(size.height_px) / u32::from(rows);
        check("terminal_resize", unsafe {
            ffi::ghostty_terminal_resize(
                self.raw,
                cols,
                rows,
                cell_width.max(1),
                cell_height.max(1),
            )
        })
    }

    pub fn snapshot(&self) -> Result<Vec<u8>, VtError> {
        let mut ptr: *mut u8 = std::ptr::null_mut();
        let mut len = 0usize;
        check("snapshot_encode_alloc", unsafe {
            ffi::ghostty_snapshot_encode_alloc(self.raw, std::ptr::null(), &mut ptr, &mut len)
        })?;
        if ptr.is_null() {
            return Ok(Vec::new());
        }
        let bytes = unsafe { std::slice::from_raw_parts(ptr, len) }.to_vec();
        unsafe { ffi::ghostty_free(std::ptr::null(), ptr, len) };
        Ok(bytes)
    }

    pub fn at_ground(&self) -> bool {
        self.get::<bool>(ffi::DATA_VT_GROUND).unwrap_or(false)
    }

    pub fn cursor(&self) -> kitty::Cursor {
        kitty::Cursor {
            col: self.get::<u16>(ffi::DATA_CURSOR_X).unwrap_or(0),
            row: self.get::<u16>(ffi::DATA_CURSOR_Y).unwrap_or(0),
        }
    }

    fn origin_mode(&self) -> bool {
        let mut config = ffi::GhosttyTerminalModeConfig {
            mode: ffi::MODE_ORIGIN,
            value: false,
        };
        let result = unsafe {
            ffi::ghostty_terminal_get(
                self.raw,
                ffi::DATA_MODE,
                &mut config as *mut ffi::GhosttyTerminalModeConfig as *mut c_void,
            )
        };
        result == ffi::SUCCESS && config.value
    }

    pub fn image_replay(&self) -> Vec<u8> {
        let (images, placements) = self.graphics();
        if placements.is_empty() {
            return Vec::new();
        }
        kitty::replay(&images, &placements, self.cursor())
    }

    fn graphics(&self) -> (Vec<kitty::Image>, Vec<kitty::Placement>) {
        let mut images = Vec::new();
        let mut placements = Vec::new();
        let Some(graphics) = self.get::<Graphics>(ffi::DATA_KITTY_GRAPHICS) else {
            return (images, placements);
        };
        if graphics.0.is_null() {
            return (images, placements);
        }
        let Some(iterator) = PlacementIterator::new() else {
            return (images, placements);
        };
        let mut handle = iterator.0;
        let populated = unsafe {
            ffi::ghostty_kitty_graphics_get(
                graphics.0,
                ffi::KITTY_DATA_PLACEMENT_ITERATOR,
                &mut handle as *mut ffi::GhosttyKittyGraphicsPlacementIterator as *mut c_void,
            )
        };
        if populated != ffi::SUCCESS {
            return (images, placements);
        }
        let origin = self.origin_mode();
        while unsafe { ffi::ghostty_kitty_graphics_placement_next(iterator.0) } {
            let field = |key| iterator.field::<u32>(key).unwrap_or(0);
            let image_id = field(ffi::PLACEMENT_IMAGE_ID);
            let image = unsafe { ffi::ghostty_kitty_graphics_image(graphics.0, image_id) };
            if image.is_null() {
                continue;
            }
            let anchor = if iterator
                .field::<bool>(ffi::PLACEMENT_IS_VIRTUAL)
                .unwrap_or(false)
            {
                kitty::Anchor::Virtual
            } else {
                let mut info = ffi::GhosttyKittyGraphicsPlacementRenderInfo {
                    size: std::mem::size_of::<ffi::GhosttyKittyGraphicsPlacementRenderInfo>(),
                    ..Default::default()
                };
                let located = unsafe {
                    ffi::ghostty_kitty_graphics_placement_render_info(
                        iterator.0, image, self.raw, &mut info,
                    )
                };
                let (Ok(col), Ok(row)) = (
                    u16::try_from(info.viewport_col),
                    u16::try_from(info.viewport_row),
                ) else {
                    continue;
                };
                if located != ffi::SUCCESS || !info.viewport_visible || origin {
                    continue;
                }
                kitty::Anchor::Cell { col, row }
            };
            if !images
                .iter()
                .any(|known: &kitty::Image| known.id == image_id)
            {
                let Some(copied) = copy_image(image, image_id) else {
                    continue;
                };
                images.push(copied);
            }
            placements.push(kitty::Placement {
                image_id,
                placement_id: field(ffi::PLACEMENT_PLACEMENT_ID),
                anchor,
                x_offset: field(ffi::PLACEMENT_X_OFFSET),
                y_offset: field(ffi::PLACEMENT_Y_OFFSET),
                source: kitty::Rect {
                    x: field(ffi::PLACEMENT_SOURCE_X),
                    y: field(ffi::PLACEMENT_SOURCE_Y),
                    width: field(ffi::PLACEMENT_SOURCE_WIDTH),
                    height: field(ffi::PLACEMENT_SOURCE_HEIGHT),
                },
                columns: field(ffi::PLACEMENT_COLUMNS),
                rows: field(ffi::PLACEMENT_ROWS),
                z: iterator.field::<i32>(ffi::PLACEMENT_Z).unwrap_or(0),
            });
        }
        (images, placements)
    }
}

struct Graphics(ffi::GhosttyKittyGraphics);

impl Default for Graphics {
    fn default() -> Self {
        Self(std::ptr::null_mut())
    }
}

struct PlacementIterator(ffi::GhosttyKittyGraphicsPlacementIterator);

impl PlacementIterator {
    fn new() -> Option<Self> {
        let mut raw: ffi::GhosttyKittyGraphicsPlacementIterator = std::ptr::null_mut();
        let result = unsafe {
            ffi::ghostty_kitty_graphics_placement_iterator_new(std::ptr::null(), &mut raw)
        };
        (result == ffi::SUCCESS && !raw.is_null()).then_some(Self(raw))
    }

    fn field<T: Default>(&self, key: std::ffi::c_int) -> Option<T> {
        let mut out = T::default();
        let result = unsafe {
            ffi::ghostty_kitty_graphics_placement_get(
                self.0,
                key,
                &mut out as *mut T as *mut c_void,
            )
        };
        (result == ffi::SUCCESS).then_some(out)
    }
}

impl Drop for PlacementIterator {
    fn drop(&mut self) {
        unsafe { ffi::ghostty_kitty_graphics_placement_iterator_free(self.0) };
    }
}

fn image_field<T: Default>(
    image: ffi::GhosttyKittyGraphicsImage,
    key: std::ffi::c_int,
) -> Option<T> {
    let mut out = T::default();
    let result = unsafe {
        ffi::ghostty_kitty_graphics_image_get(image, key, &mut out as *mut T as *mut c_void)
    };
    (result == ffi::SUCCESS).then_some(out)
}

fn copy_image(image: ffi::GhosttyKittyGraphicsImage, id: u32) -> Option<kitty::Image> {
    let format = match image_field::<std::ffi::c_int>(image, ffi::IMAGE_FORMAT)? {
        ffi::FORMAT_RGB => kitty::Format::Rgb,
        ffi::FORMAT_RGBA => kitty::Format::Rgba,
        ffi::FORMAT_GRAY => kitty::Format::Gray,
        ffi::FORMAT_GRAY_ALPHA => kitty::Format::GrayAlpha,
        _ => return None,
    };
    let width = image_field::<u32>(image, ffi::IMAGE_WIDTH)?;
    let height = image_field::<u32>(image, ffi::IMAGE_HEIGHT)?;
    let ptr = image_field::<usize>(image, ffi::IMAGE_DATA_PTR)? as *const u8;
    let len = image_field::<usize>(image, ffi::IMAGE_DATA_LEN)?;
    if ptr.is_null() || len == 0 {
        return None;
    }
    let pixels = unsafe { std::slice::from_raw_parts(ptr, len) }.to_vec();
    Some(kitty::Image {
        id,
        width,
        height,
        format,
        pixels,
    })
}

fn install_png_decoder() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| unsafe {
        let decoder: ffi::GhosttySysDecodePngFn = decode_png;
        ffi::ghostty_sys_set(ffi::SYS_OPT_DECODE_PNG, decoder as *const c_void);
    });
}

unsafe extern "C" fn decode_png(
    _userdata: *mut c_void,
    allocator: *const ffi::GhosttyAllocator,
    data: *const u8,
    data_len: usize,
    out: *mut ffi::GhosttySysImage,
) -> bool {
    if data.is_null() || out.is_null() {
        return false;
    }
    let input = unsafe { std::slice::from_raw_parts(data, data_len) };
    let Some((width, height, rgba)) = png_to_rgba(input) else {
        return false;
    };
    let buffer = unsafe { ffi::ghostty_alloc(allocator, rgba.len()) };
    if buffer.is_null() {
        return false;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(rgba.as_ptr(), buffer, rgba.len());
        *out = ffi::GhosttySysImage {
            width,
            height,
            data: buffer,
            data_len: rgba.len(),
        };
    }
    true
}

fn png_to_rgba(input: &[u8]) -> Option<(u32, u32, Vec<u8>)> {
    let mut decoder = png::Decoder::new(input);
    decoder.set_transformations(png::Transformations::normalize_to_color8());
    let mut reader = decoder.read_info().ok()?;
    let mut buffer = vec![0; reader.output_buffer_size()];
    let frame = reader.next_frame(&mut buffer).ok()?;
    let pixels = &buffer[..frame.buffer_size()];
    let rgba = match frame.color_type {
        png::ColorType::Rgba => pixels.to_vec(),
        png::ColorType::Rgb => pixels
            .chunks_exact(3)
            .flat_map(|p| [p[0], p[1], p[2], 255])
            .collect(),
        png::ColorType::GrayscaleAlpha => pixels
            .chunks_exact(2)
            .flat_map(|p| [p[0], p[0], p[0], p[1]])
            .collect(),
        png::ColorType::Grayscale => pixels.iter().flat_map(|&v| [v, v, v, 255]).collect(),
        png::ColorType::Indexed => return None,
    };
    Some((frame.width, frame.height, rgba))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn terminal() -> Terminal {
        Terminal::new(
            Size {
                cols: 20,
                rows: 5,
                width_px: 200,
                height_px: 100,
            },
            &Options {
                scrollback_lines: 100,
                scrollback_bytes: 1 << 20,
                image_bytes: 1 << 24,
            },
        )
        .unwrap()
    }

    #[test]
    fn a_snapshot_is_a_ghostsnp_record() {
        let mut vt = terminal();
        vt.write(b"hello");
        let snapshot = vt.snapshot().unwrap();
        assert!(
            snapshot.starts_with(b"GHOSTSNP"),
            "{:?}",
            &snapshot[..16.min(snapshot.len())]
        );
    }

    #[test]
    fn ground_is_lost_mid_sequence_and_found_after() {
        let mut vt = terminal();
        assert!(vt.at_ground());
        vt.write(b"\x1b]0;tit");
        assert!(!vt.at_ground());
        vt.write(b"le\x07");
        assert!(vt.at_ground());
    }

    #[test]
    fn the_cursor_is_read_back() {
        let mut vt = terminal();
        vt.write(b"\x1b[3;7H");
        assert_eq!(vt.cursor(), kitty::Cursor { col: 6, row: 2 });
    }

    #[test]
    fn a_placed_image_is_replayed() {
        let mut vt = terminal();
        vt.write(b"\x1b[2;3H\x1b_Ga=T,f=32,s=1,v=1,i=4,q=2;/wAA/w==\x1b\\\x1b[5;1H");
        let replay = String::from_utf8(vt.image_replay()).unwrap();
        assert!(replay.contains("a=t,f=32,s=1,v=1,i=4"), "{replay:?}");
        assert!(replay.contains("\x1b[2;3H\x1b_Ga=p,i=4"), "{replay:?}");
        assert!(replay.ends_with("\x1b[5;1H"), "{replay:?}");
    }

    #[test]
    fn a_png_is_decoded_and_kept() {
        let mut encoded = Vec::new();
        {
            let mut encoder = png::Encoder::new(&mut encoded, 1, 1);
            encoder.set_color(png::ColorType::Rgb);
            encoder.set_depth(png::BitDepth::Eight);
            let mut writer = encoder.write_header().unwrap();
            writer.write_image_data(&[1, 2, 3]).unwrap();
        }
        assert_eq!(png_to_rgba(&encoded), Some((1, 1, vec![1, 2, 3, 255])));
        let mut vt = terminal();
        let command = format!(
            "\x1b_Ga=T,f=100,i=8,q=2;{}\x1b\\",
            crate::util::base64_encode(&encoded)
        );
        vt.write(command.as_bytes());
        let replay = String::from_utf8(vt.image_replay()).unwrap();
        assert!(replay.contains("f=32,s=1,v=1,i=8"), "{replay:?}");
    }
}
