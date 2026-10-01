use crate::util::base64_encode;

const CHUNK: usize = 4096;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Format {
    Rgb,
    Rgba,
    Gray,
    GrayAlpha,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Image {
    pub id: u32,
    pub width: u32,
    pub height: u32,
    pub format: Format,
    pub pixels: Vec<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Rect {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Anchor {
    Virtual,
    Cell { col: u16, row: u16 },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Placement {
    pub image_id: u32,
    pub placement_id: u32,
    pub anchor: Anchor,
    pub x_offset: u32,
    pub y_offset: u32,
    pub source: Rect,
    pub columns: u32,
    pub rows: u32,
    pub z: i32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cursor {
    pub col: u16,
    pub row: u16,
}

pub fn replay(images: &[Image], placements: &[Placement], cursor: Cursor) -> Vec<u8> {
    let mut out = Vec::new();
    let mut sent: Vec<u32> = Vec::new();
    let mut moved = false;
    for placement in placements {
        let Some(image) = images.iter().find(|image| image.id == placement.image_id) else {
            continue;
        };
        if !sent.contains(&image.id) {
            transmit(&mut out, image);
            sent.push(image.id);
        }
        if let Anchor::Cell { col, row } = placement.anchor {
            out.extend_from_slice(format!("\x1b[{};{}H", row + 1, col + 1).as_bytes());
            moved = true;
        }
        place(&mut out, placement);
    }
    if moved {
        out.extend_from_slice(format!("\x1b[{};{}H", cursor.row + 1, cursor.col + 1).as_bytes());
    }
    out
}

fn transmit(out: &mut Vec<u8>, image: &Image) {
    let (format, pixels) = widen(image);
    let compressed = miniz_oxide::deflate::compress_to_vec_zlib(&pixels, 6);
    let encoded = base64_encode(&compressed);
    let chunks: Vec<&[u8]> = encoded.as_bytes().chunks(CHUNK).collect();
    let last = chunks.len().saturating_sub(1);
    if chunks.is_empty() {
        return;
    }
    for (index, chunk) in chunks.iter().enumerate() {
        let more = u8::from(index != last);
        if index == 0 {
            out.extend_from_slice(
                format!(
                    "\x1b_Ga=t,f={format},s={},v={},i={},o=z,q=2,m={more};",
                    image.width, image.height, image.id
                )
                .as_bytes(),
            );
        } else {
            out.extend_from_slice(format!("\x1b_Gq=2,m={more};").as_bytes());
        }
        out.extend_from_slice(chunk);
        out.extend_from_slice(b"\x1b\\");
    }
}

fn widen(image: &Image) -> (u8, std::borrow::Cow<'_, [u8]>) {
    match image.format {
        Format::Rgb => (24, image.pixels.as_slice().into()),
        Format::Rgba => (32, image.pixels.as_slice().into()),
        Format::Gray => (
            24,
            image
                .pixels
                .iter()
                .flat_map(|&v| [v, v, v])
                .collect::<Vec<u8>>()
                .into(),
        ),
        Format::GrayAlpha => (
            32,
            image
                .pixels
                .chunks_exact(2)
                .flat_map(|pair| [pair[0], pair[0], pair[0], pair[1]])
                .collect::<Vec<u8>>()
                .into(),
        ),
    }
}

fn place(out: &mut Vec<u8>, placement: &Placement) {
    let mut keys = format!("a=p,i={}", placement.image_id);
    let mut key = |name: &str, value: u32| {
        if value != 0 {
            keys.push_str(&format!(",{name}={value}"));
        }
    };
    key("p", placement.placement_id);
    key("X", placement.x_offset);
    key("Y", placement.y_offset);
    key("x", placement.source.x);
    key("y", placement.source.y);
    key("w", placement.source.width);
    key("h", placement.source.height);
    key("c", placement.columns);
    key("r", placement.rows);
    if placement.z != 0 {
        keys.push_str(&format!(",z={}", placement.z));
    }
    match placement.anchor {
        Anchor::Virtual => keys.push_str(",U=1"),
        Anchor::Cell { .. } => keys.push_str(",C=1"),
    }
    keys.push_str(",q=2");
    out.extend_from_slice(b"\x1b_G");
    out.extend_from_slice(keys.as_bytes());
    out.extend_from_slice(b"\x1b\\");
}

#[cfg(test)]
mod tests {
    use super::*;

    fn image(id: u32, format: Format, pixels: Vec<u8>) -> Image {
        Image {
            id,
            width: 1,
            height: 1,
            format,
            pixels,
        }
    }

    fn placement(image_id: u32, anchor: Anchor) -> Placement {
        Placement {
            image_id,
            placement_id: 0,
            anchor,
            x_offset: 0,
            y_offset: 0,
            source: Rect::default(),
            columns: 0,
            rows: 0,
            z: 0,
        }
    }

    fn text(bytes: &[u8]) -> String {
        String::from_utf8(bytes.to_vec()).unwrap()
    }

    #[test]
    fn nothing_placed_writes_nothing() {
        let images = [image(1, Format::Rgba, vec![0; 4])];
        assert!(replay(&images, &[], Cursor { col: 0, row: 0 }).is_empty());
    }

    #[test]
    fn a_cell_placement_moves_places_and_puts_the_cursor_back() {
        let images = [image(7, Format::Rgba, vec![1, 2, 3, 4])];
        let mut placed = placement(7, Anchor::Cell { col: 4, row: 2 });
        placed.placement_id = 3;
        placed.columns = 10;
        placed.z = -1;
        let out = text(&replay(&images, &[placed], Cursor { col: 9, row: 5 }));
        assert!(out.starts_with("\x1b_Ga=t,f=32,s=1,v=1,i=7,o=z,q=2,m=0;"));
        assert!(out.contains("\x1b[3;5H\x1b_Ga=p,i=7,p=3,c=10,z=-1,C=1,q=2\x1b\\"));
        assert!(out.ends_with("\x1b[6;10H"));
    }

    #[test]
    fn a_virtual_placement_leaves_the_cursor_alone() {
        let images = [image(2, Format::Rgb, vec![0; 3])];
        let out = text(&replay(
            &images,
            &[placement(2, Anchor::Virtual)],
            Cursor { col: 0, row: 0 },
        ));
        assert!(out.ends_with("\x1b_Ga=p,i=2,U=1,q=2\x1b\\"));
        assert!(!out.contains("\x1b["));
    }

    #[test]
    fn an_image_placed_twice_is_sent_once() {
        let images = [image(5, Format::Rgba, vec![0; 4])];
        let placements = [
            placement(5, Anchor::Cell { col: 0, row: 0 }),
            placement(5, Anchor::Cell { col: 1, row: 1 }),
        ];
        let out = text(&replay(&images, &placements, Cursor { col: 0, row: 0 }));
        assert_eq!(out.matches("a=t").count(), 1);
        assert_eq!(out.matches("a=p").count(), 2);
    }

    #[test]
    fn a_placement_without_its_image_is_skipped() {
        let out = replay(
            &[],
            &[placement(9, Anchor::Virtual)],
            Cursor { col: 0, row: 0 },
        );
        assert!(out.is_empty());
    }

    #[test]
    fn a_large_image_is_chunked_and_ends_on_m0() {
        let mut big = image(1, Format::Rgba, Vec::new());
        big.width = 256;
        big.height = 256;
        let mut seed = 0x2545_f491_u32;
        big.pixels = (0..256 * 256 * 4)
            .map(|_| {
                seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                (seed >> 24) as u8
            })
            .collect();
        let out = text(&replay(
            &[big],
            &[placement(1, Anchor::Virtual)],
            Cursor { col: 0, row: 0 },
        ));
        assert!(out.contains("m=1;"));
        assert_eq!(out.matches("m=0;").count(), 1);
        assert!(out.split("\x1b_G").all(|cmd| cmd.len() <= CHUNK + 64));
    }

    #[test]
    fn gray_widens_to_what_kitty_takes() {
        let gray = image(1, Format::Gray, vec![9]);
        let (format, pixels) = widen(&gray);
        assert_eq!((format, &*pixels), (24, &[9, 9, 9][..]));
        let gray_alpha = image(1, Format::GrayAlpha, vec![9, 200]);
        let (format, pixels) = widen(&gray_alpha);
        assert_eq!((format, &*pixels), (32, &[9, 9, 9, 200][..]));
    }
}
