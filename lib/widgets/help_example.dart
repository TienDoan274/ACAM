/// Ảnh mẫu hướng dẫn trong panel chỉnh tay (vẽ từ dữ liệu có nhãn bởi `pipelines/tools/make_help_images.py`
/// ở repo cha). Chạm -> xem ảnh đầy đủ toàn màn hình (route fullscreen: modal sheet không hiển thị trên
/// máy test).
library help_example;

import 'package:flutter/material.dart';

class HelpExample extends StatelessWidget {
  final String thumbAsset;
  final String fullAsset;
  final String caption;
  final String title;

  const HelpExample({super.key, required this.thumbAsset, required this.fullAsset, required this.caption, required this.title});

  /// Mở ảnh mẫu toàn màn hình (zoom được).
  static void show(BuildContext context, String asset, String title) => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => Scaffold(
            backgroundColor: Colors.black,
            appBar: AppBar(
              toolbarHeight: 44,
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              title: Text(title, style: const TextStyle(fontSize: 14)),
            ),
            body: Center(
              child: InteractiveViewer(maxScale: 6, child: Image.asset(asset, fit: BoxFit.contain)),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => show(context, fullAsset, title),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.asset(thumbAsset, fit: BoxFit.fitWidth),
          ),
          const SizedBox(height: 3),
          Row(children: [
            Icon(Icons.zoom_in, size: 14, color: Colors.grey[600]),
            const SizedBox(width: 4),
            Expanded(child: Text(caption, style: TextStyle(fontSize: 11, color: Colors.grey[600]))),
          ]),
        ],
      ),
    );
  }
}
