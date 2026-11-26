// Tiny JPEG stand-ins for the extension tests: a start marker, a JFIF header and a frame header (SOF0) that carries
// the size, with no image data. Also the image APIs the service worker has and Node lacks (createImageBitmap,
// OffscreenCanvas), faked on top of that header so a scaled-down screenshot reports its new size.
"use strict";

function fakeJpegBytes(width, height) {
  return Uint8Array.from([
    0xff, 0xd8, // SOI
    0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, // APP0
    0xff, 0xc0, 0x00, 0x11, 0x08, // SOF0, length 17, 8-bit samples
    (height >> 8) & 0xff, height & 0xff,
    (width >> 8) & 0xff, width & 0xff,
    0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01, // three components
    0xff, 0xd9 // EOI
  ]);
}

function fakeJpeg(width, height) {
  return Buffer.from(fakeJpegBytes(width, height)).toString("base64");
}

// Width and height from the frame header, or null.
function jpegSizeOf(bytes) {
  for (let i = 2; i + 9 <= bytes.length; ) {
    if (bytes[i] !== 0xff) return null;
    if (bytes[i + 1] === 0xc0) {
      return { height: (bytes[i + 5] << 8) | bytes[i + 6], width: (bytes[i + 7] << 8) | bytes[i + 8] };
    }
    i += 2 + ((bytes[i + 2] << 8) | bytes[i + 3]);
  }
  return null;
}

function base64Size(base64) {
  return jpegSizeOf(Buffer.from(base64, "base64"));
}

/** createImageBitmap and OffscreenCanvas for the vm context. `log` collects each canvas size drawn. */
function fakeImageApis(log = []) {
  async function createImageBitmap(blob) {
    const size = jpegSizeOf(new Uint8Array(await blob.arrayBuffer()));
    if (!size) throw new Error("The source image could not be decoded.");
    return { ...size, close() {} };
  }

  class OffscreenCanvas {
    constructor(width, height) {
      this.width = width;
      this.height = height;
    }

    getContext() {
      return { imageSmoothingQuality: "low", drawImage() {} };
    }

    async convertToBlob() {
      log.push([this.width, this.height]);
      return new Blob([fakeJpegBytes(this.width, this.height)], { type: "image/jpeg" });
    }
  }

  return { createImageBitmap, OffscreenCanvas };
}

module.exports = { fakeJpeg, base64Size, fakeImageApis };
