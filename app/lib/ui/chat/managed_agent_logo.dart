import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Same Agent marks as the desktop plugin; see docs/managed-agent-mobile.md.
class ManagedAgentLogo extends StatelessWidget {
  const ManagedAgentLogo({super.key, required this.agentId, this.size = 18});
  final String agentId;
  final double size;
  static final _codex = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAMAAACdt4HsAAAAclBMVEX////v7+++wMf////s7O3k5OTExcrX2Ny6vMTv8PPW19yXmqRqboJmaHd3eoaqrLPs7fGMjpfb3eKlpq1eYXOxs7pWWWd+gY5HSVdRVGVub3k+QU74+Pg4OkcvMT1ISlUoKjUiIy4fICueoKkaGyUSFB21Bp+qAAAAAXRSTlMAQObYZgAABChJREFUWMPtl916qjoQhlsdEwIECEgMYCBxx/u/xT1DrFUL1LO1DtY8LSLJvPnmB4gfH//sr7TPDfvdebf/xXZbkE/4zZ0MVhGHd9zJDsv+7F3//Z69tT5wljAu3tXw+TIlzXKJlhflYmJ+5uF5WpWhb54X+C/zZCmT2wJA4dJZwus0UYjIGqWyMhVbEp4yKNRRqlv0opW5PJLJ4rFJXvP4JKDRMqturBZjkMVJFYjR6iHQDQDI4+k2k51wZbWrqwp4mR/1CVYATyko9TFGxBUqL5IvMbXSWt0T8bkGgFLqgqZBI/Uxbx5UAxLaNcCNLBpttM7wbCc1pmJOpWAsDtey68UaQMyrFgb9uxLPjqg3+nGluyKN0XUdWw0BJ0NvTFFqgzpr9J+Dh4w0Ga1qkqBNswagxdRgFPAbgHRQG5jumGWyMxrTIaRRa4AzFs0YrNMXgI4MJWnsKYFhGNMnIh/mBOPsV8CZBFjN9w8ArowxnZzDr5IcvxTaKpxJCVsoI3SWysz1UM4AqQdzlCgho1IKrK+x1mKFzisANtgEU8E7GwHDgOqxe4w9tnM166wbaA2xBMBLrTWcAGYGdCiYVUJUrMCF+7l6gklrW1RwPi8ByjuActANqhKzVWoYrFGcCFzbDgNaBrTWpncFQMcI2DfWoAiDqRCiHcYM/ZdCEKkZqfR8spj4F0CiJjv2gHL6URNoCQDaYacL6O1oFDO2eQDUFP7AKdCRdC4CRDZaNifbjA41l/uYb/SZMAFNTBGzY7sG4J2jTsJgToOzIzXF3HZqBpSOAGduXbkGEKV1OqVGqRJpRxtvwbSw5IqAiUJItwBCOT9R32FCGo3nCkAN3t0UTBRC6zDONcBeOee9pr4T+ASbnDOdc5OmtREwEEB5w8Wqgt4bOV5c7Lt9iiK8zdP/IsBbutUGX4gNwEVCqd3FUt/xYnRWt7BvPBYQjwjAGXa3ASguHVAZ/WXKlA3eZDX1wRegFsr7E2wAlB9xFbx/7MV70kFT8aqNgLL3F8nFBmA3hrn/IJHjKJOK2oj1WI4Z4FzwN/81AOhgYD6v2xbIvaZIurLC9AfvB1WLTYAoXejF1xeBL5cpBIyEbmxkZymIXwDQh1BAfOrhI1lfwtgz8tozF5T4ttf3+32AyxC6klwAgw/YVTHpoK82xYt3wLP/Bw4AAI4D7/01TLKXBj9NEz2wEuGiKpoy68S/FwCLMQAZ3gXhihaCa25vQo6RyToOz9PE6wYjJgGi1YnqZX8qMIK+TDlnargGzSv4NvFjlwXf/nfLLMrAB4O/Xl3BH0d+RIASFgDA8IYMIXgr2+cBsbDdPSwAAHjSZFmb3txETCKIxc0uWwI8rxsLJcTiVndNwyMgKljbbNN2/zcEAja2+4RgIDYN2Bu/WtAOaEodnu2dnzz/7I/Y/w/LaEcX/MdfAAAAAElFTkSuQmCC',
  );
  @override
  Widget build(BuildContext context) => Semantics(
    label: agentId,
    child: SizedBox(
      width: size,
      height: size,
      child: agentId == 'codex'
          ? Image.memory(_codex)
          : agentId == 'claude'
          ? CustomPaint(painter: _ClaudeMark())
          : Center(child: Text(agentId.substring(0, 1).toUpperCase())),
    ),
  );
}

class _ClaudeMark extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..color = const Color(0xffd97757)
      ..strokeWidth = size.width / 10;
    for (var i = 0; i < 12; i++) {
      final a = i * math.pi / 6;
      canvas.drawLine(
        center + Offset(math.cos(a), math.sin(a)) * (size.width * .15),
        center + Offset(math.cos(a), math.sin(a)) * (size.width * .47),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
