// lib/ui/share_link.dart
//
// The address others at home open to join the LAN party: a link that opens
// it, a button that shares it (Android's share sheet, a phone browser's) or
// copies it (desktop), and a QR code for phones.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../platform/share.dart';

const _green = Color(0xFF32D25A);
const _dim = Color(0xFF8C8C8C);

class ShareLink extends StatelessWidget {
  final String url;

  /// Size of the QR code under the link; none when 0.
  final double qrSize;
  const ShareLink({super.key, required this.url, this.qrSize = 0});

  Future<void> _share(BuildContext context) async {
    if (await shareText('Join my Brood LAN party: open $url in your browser.')) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Copied $url')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => openUrl(url),
                  child: Text(
                    url,
                    style: const TextStyle(fontSize: 15, color: _green, decoration: TextDecoration.underline, decorationColor: _green),
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: canShare ? 'Share the link' : 'Copy the link',
              visualDensity: VisualDensity.compact,
              onPressed: () => _share(context),
              icon: Icon(canShare ? Icons.share : Icons.copy, size: 18, color: _dim),
            ),
          ],
        ),
        if (qrSize > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: QrImageView(
              data: url,
              size: qrSize,
              padding: const EdgeInsets.all(6),
              backgroundColor: Colors.white,
              semanticsLabel: 'QR code of $url',
            ),
          ),
      ],
    );
  }
}
