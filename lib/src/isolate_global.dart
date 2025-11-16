import 'dart:isolate';
import 'dart:typed_data';
import 'package:esc_pos_utils/src/commands.dart';
import 'package:image/image.dart';

class IsolateFunctions {
  static void imageIsolateEntry(List<dynamic> args) {
    final SendPort send = args[0];
    List<int> bytes = args[1];

    final Image image = Image.from(args[3]); // make a copy
    const bool highDensityHorizontal = true;
    const bool highDensityVertical = true;

    invert(image);
    flip(image, direction: FlipDirection.horizontal);
    final Image imageRotated = copyRotate(image, angle: 270);

    const int lineHeight = highDensityVertical ? 3 : 1;
    final List<List<int>> blobs = toColumnFormat(imageRotated, lineHeight * 8);

    // Compress according to line density
    // Line height contains 8 or 24 pixels of src image
    // Each blobs[i] contains greyscale bytes [0-255]
    // const int pxPerLine = 24 ~/ lineHeight;
    for (int blobInd = 0; blobInd < blobs.length; blobInd++) {
      blobs[blobInd] = packBitsIntoBytes(blobs[blobInd]);
    }

    final int heightPx = imageRotated.height;
    const int densityByte =
        (highDensityHorizontal ? 1 : 0) + (highDensityVertical ? 32 : 0);

    final List<int> header = List.from(cBitImg.codeUnits);
    header.add(densityByte);
    header.addAll(intLowHigh(heightPx, 2));

    // Adjust line spacing (for 16-unit line feeds): ESC 3 0x10 (HEX: 0x1b 0x33 0x10)
    bytes += [27, 51, 16];
    for (int i = 0; i < blobs.length; ++i) {
      bytes += List.from(header)
        ..addAll(blobs[i])
        ..addAll('\n'.codeUnits);
    }
    // Reset line spacing: ESC 2 (HEX: 0x1b 0x32)
    bytes += [27, 50];
    send.send(bytes);
  }

  static void imageRasterIsolateEntry(List<dynamic> args) {
    final SendPort send = args[0];
    List<int> bytes = args[1];
    final image = args[2];
    const bool highDensityHorizontal = true;
    const bool highDensityVertical = true;
    final int widthPx = image.width;
    final int heightPx = image.height;
    final int widthBytes = (widthPx + 7) ~/ 8;
    final List<int> resterizedData = _toRasterFormat(image);

    // GS v 0
    final int densityByte =
        (highDensityVertical ? 0 : 1) + (highDensityHorizontal ? 0 : 2);

    final List<int> header = List.from(cRasterImg2.codeUnits);
    header.add(densityByte); // m
    header.addAll(intLowHigh(widthBytes, 2)); // xL xH
    header.addAll(intLowHigh(heightPx, 2)); // yL yH
    bytes += List.from(header)..addAll(resterizedData);

    send.send(bytes);
  }

  static int transformUint32Bool(int uint32, int shift, bool newValue) {
    return ((0xFFFFFFFF ^ (0x1 << shift)) & uint32) |
        ((newValue ? 1 : 0) << shift);
  }

  static List<int> packBitsIntoBytes(List<int> bytes) {
    const pxPerLine = 8;
    final List<int> res = <int>[];
    const threshold = 127; // set the greyscale -> b/w threshold here
    for (int i = 0; i < bytes.length; i += pxPerLine) {
      int newVal = 0;
      for (int j = 0; j < pxPerLine; j++) {
        newVal = transformUint32Bool(
          newVal,
          pxPerLine - j,
          bytes[i + j] > threshold,
        );
      }
      res.add(newVal ~/ 2);
    }
    return res;
  }

  static List<int> intLowHigh(int value, int bytesNb) {
    final dynamic maxInput = 256 << (bytesNb * 8) - 1;

    if (bytesNb < 1 || bytesNb > 4) {
      throw Exception('Can only output 1-4 bytes');
    }
    if (value < 0 || value > maxInput) {
      throw Exception(
          'Number is too large. Can only output up to $maxInput in $bytesNb bytes');
    }

    final List<int> res = <int>[];
    int buf = value;
    for (int i = 0; i < bytesNb; ++i) {
      res.add(buf % 256);
      buf = buf ~/ 256;
    }
    return res;
  }

  static List<List<int>> toColumnFormat(Image imgSrc, int lineHeight) {
    final Image image = Image.from(imgSrc); // make a copy

    // Determine new width: closest integer that is divisible by lineHeight
    final int widthPx = (image.width + lineHeight) - (image.width % lineHeight);
    final int heightPx = image.height;

    // Create a black bottom layer
    final biggerImage = copyResize(image, width: widthPx, height: heightPx);
    fill(biggerImage, color: ColorRgb8(0, 0, 0));
    // Insert source image into bigger one
    compositeImage(biggerImage, image, dstX: 0, dstY: 0);

    int left = 0;
    final List<List<int>> blobs = [];

    while (left < widthPx) {
      final Image slice = copyCrop(biggerImage,
          x: left, y: 0, width: lineHeight, height: heightPx);
      grayscale(slice);
      final imgBinary = slice.convert(numChannels: 1);
      final Uint8List bytes = imgBinary.getBytes();
      blobs.add(bytes);
      left += lineHeight;
    }

    return blobs;
  }

  static List<int> _toRasterFormat(Image imgSrc) {
    final Image image = Image.from(imgSrc); // make a copy
    final int widthPx = image.width;
    final int heightPx = image.height;

    grayscale(image);
    invert(image);

    // R/G/B channels are same -> keep only one channel
    final List<int> oneChannelBytes = [];
    final List<int> buffer = image.getBytes(order: ChannelOrder.rgba);
    for (int i = 0; i < buffer.length; i += 4) {
      oneChannelBytes.add(buffer[i]);
    }

    // Add some empty pixels at the end of each line (to make the width divisible by 8)
    if (widthPx % 8 != 0) {
      final targetWidth = (widthPx + 8) - (widthPx % 8);
      final missingPx = targetWidth - widthPx;
      final extra = Uint8List(missingPx);
      for (int i = 0; i < heightPx; i++) {
        final pos = (i * widthPx + widthPx) + i * missingPx;
        oneChannelBytes.insertAll(pos, extra);
      }
    }

    // Pack bits into bytes
    return _packBitsIntoBytes(oneChannelBytes);
  }

  static List<int> _packBitsIntoBytes(List<int> bytes) {
    const pxPerLine = 8;
    final List<int> res = <int>[];
    const threshold = 127; // set the greyscale -> b/w threshold here
    for (int i = 0; i < bytes.length; i += pxPerLine) {
      int newVal = 0;
      for (int j = 0; j < pxPerLine; j++) {
        newVal = _transformUint32Bool(
          newVal,
          pxPerLine - j,
          bytes[i + j] > threshold,
        );
      }
      res.add(newVal ~/ 2);
    }
    return res;
  }

  static int _transformUint32Bool(int uint32, int shift, bool newValue) {
    return ((0xFFFFFFFF ^ (0x1 << shift)) & uint32) |
        ((newValue ? 1 : 0) << shift);
  }
}
