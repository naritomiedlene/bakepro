import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Logo centralizado do BakePro com altura consistente e "snap" para pixels do device.
///
/// Use este widget nas telas de auth (Login, Troca de senha etc.) para manter
/// alinhamento, nitidez e tamanhos consistentes.
class BakeProCenteredLogo extends StatelessWidget {
  /// Altura padrão pensada para telas de autenticação.
  ///
  /// Para telas pós-login (AppShell / áreas internas), prefira passar um
  /// `height` maior diretamente no ponto de uso.
  const BakeProCenteredLogo({super.key, this.height = 135});

  static const _logoAsset = 'assets/images/BakePro_vetorial.svg';
  final double height;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final snappedHeight = _snapToDevicePixels(height, dpr);
    return Semantics(
      label: 'BakePro',
      image: true,
      child: RepaintBoundary(
        child: SvgPicture.asset(
          _logoAsset,
          height: snappedHeight,
          alignment: Alignment.center,
          fit: BoxFit.contain,
        ),
      ),
    );
  }

  double _snapToDevicePixels(double logicalPx, double devicePixelRatio) {
    if (devicePixelRatio <= 0) return logicalPx;
    return (logicalPx * devicePixelRatio).round() / devicePixelRatio;
  }
}
