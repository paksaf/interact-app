// SPDX-License-Identifier: AGPL-3.0
//
// Crop a picked photo before applying as chat wallpaper (≤1080p).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';

Future<File?> cropChatWallpaperImage(BuildContext context, File source) async {
  final cropped = await ImageCropper().cropImage(
    sourcePath: source.path,
    maxWidth: 1920,
    maxHeight: 1080,
    compressQuality: 85,
    uiSettings: [
      AndroidUiSettings(
        toolbarTitle: 'Crop wallpaper',
        toolbarWidgetColor: Colors.white,
        initAspectRatio: CropAspectRatioPreset.original,
        lockAspectRatio: false,
      ),
      IOSUiSettings(
        title: 'Crop wallpaper',
        aspectRatioLockEnabled: false,
      ),
    ],
  );
  if (cropped == null) return null;
  return File(cropped.path);
}
