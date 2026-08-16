import 'package:submersion/features/dive_log/domain/entities/dive.dart'
    show GasMix;

/// Partial-pressure gas blending with real-gas (Van der Waals) behaviour.
///
/// Given a cylinder's starting fill (pressure + mix) and a desired end fill,
/// this computes the fill order and the intermediate pressures to top up to,
/// using up to three fill gases (e.g. oxygen, air, helium). Helium/nitrox are
/// handled by the same solver: a two-gas linear solve for nitrox targets and a
/// three-gas solve for trimix.
///
/// Ported from the Blei-Log blender. All pressures are in bar; the virial
/// coefficients are calibrated for bar, so callers must convert other pressure
/// units before calling and convert results back for display.

// Virial coefficients (bar) for the compressibility factor of each component.
const List<double> _o2Coef = [
  -7.18092073703e-04,
  2.81852572808e-06,
  -1.50290620492e-09,
];
const List<double> _n2Coef = [
  -2.19260353292e-04,
  2.92844845532e-06,
  -2.07613482075e-09,
];
const List<double> _heCoef = [
  4.87320026468e-04,
  -8.83632921053e-08,
  5.33304543646e-11,
];

double _virial(double p, List<double> c) =>
    c[0] * p + c[1] * p * p + c[2] * p * p * p;

double _fO2(GasMix m) => m.o2 / 100;
double _fHe(GasMix m) => m.he / 100;
double _fN2(GasMix m) => (100 - m.o2 - m.he) / 100;

/// Real-gas compressibility factor Z of [m] at pressure [p] bar.
double zFactor(double p, GasMix m) =>
    1 +
    _fO2(m) * _virial(p, _o2Coef) +
    _fHe(m) * _virial(p, _heCoef) +
    _fN2(m) * _virial(p, _n2Coef);

/// Surface-equivalent ("normal") gas volume for [p] bar of mix [m], per unit
/// cylinder volume.
double normalVolume(double p, GasMix m) => p * zFactor(1, m) / zFactor(p, m);

/// Inverse of [normalVolume]: the real pressure (bar) holding surface volume
/// [vol] of mix [m]. Fixed-point iteration (Z depends on the pressure sought).
double pressureForVolume(GasMix m, double vol) {
  var p = vol;
  for (var i = 0; i < 100; i++) {
    final pNew = vol * zFactor(p, m) / zFactor(1, m);
    if ((pNew - p).abs() < 0.0001) {
      p = pNew;
      break;
    }
    p = pNew;
  }
  return p;
}

/// Why a blend cannot be produced. Mapped to a localized message by the UI.
enum BlendError {
  targetPressureNotHigher,
  invalidMix,
  identicalNitroxGases,
  linearlyDependentGases,
  negativeAmountRequired,

  /// The cylinder already holds helium that the target mix does not allow.
  /// Topping up dilutes helium but can never remove it.
  cannotRemoveHelium,

  /// A helium-free target needs two helium-free fill gases to blend between.
  insufficientFillGases,

  /// The computed procedure does not land on the requested mix. A guard
  /// against a solver that reports a target it did not actually reach.
  targetNotReached,
}

class BlendException implements Exception {
  const BlendException(this.error, {this.drainToBar});
  final BlendError error;

  /// For [BlendError.negativeAmountRequired]: the pressure the cylinder must
  /// be drained down to before this blend becomes possible. Null when the
  /// blend fails for a reason draining cannot fix.
  final double? drainToBar;
}

/// One line of the fill procedure.
class BlendStep {
  const BlendStep({
    required this.fillGas,
    required this.pressureBar,
    required this.resultingMix,
    required this.addedVolumePerLiter,
  });

  /// The gas topped up in this step; null for the starting condition.
  final GasMix? fillGas;

  /// Fill the cylinder up to this pressure (bar). For the starting step this
  /// is the pressure already in the cylinder.
  final double pressureBar;

  /// The mix in the cylinder after this step.
  final GasMix resultingMix;

  /// Surface-equivalent volume of [fillGas] added per litre of cylinder
  /// volume; null for the starting step.
  final double? addedVolumePerLiter;
}

class BlendResult {
  const BlendResult({required this.steps});

  /// Starting condition first, then one entry per fill gas.
  final List<BlendStep> steps;
}

class GasBlenderInputs {
  const GasBlenderInputs({
    required this.startPressureBar,
    required this.start,
    required this.targetPressureBar,
    required this.target,
    required this.fillGas1,
    required this.fillGas2,
    required this.fillGas3,
  });

  final double startPressureBar;
  final GasMix start;
  final double targetPressureBar;
  final GasMix target;

  /// Fill gases, applied in this order. A trimix target uses all three; a
  /// helium-free target uses the first two helium-free ones and skips the
  /// helium source.
  final GasMix fillGas1;
  final GasMix fillGas2;
  final GasMix fillGas3;
}

/// Fill amounts smaller than this (surface volume per litre of cylinder) are
/// treated as nothing: below a hundredth of a bar in a 1 L cylinder, no fill
/// station can meter them and no gauge can show them.
const double _volumeTolerance = 0.01;

/// Percentage points below which a mix counts as helium-free.
const double _heliumEpsilon = 1e-9;

bool _isHeliumFree(GasMix m) => m.he <= _heliumEpsilon;

void _validateMix(GasMix m) {
  if (m.o2 < 0 || m.he < 0 || m.o2 + m.he > 100) {
    throw const BlendException(BlendError.invalidMix);
  }
}

GasMix _blend(GasMix a, double volA, GasMix b, double volB) {
  final total = volA + volB;
  if (total <= 0) return a;
  return GasMix(
    o2: 100 * (_fO2(a) * volA + _fO2(b) * volB) / total,
    he: 100 * (_fHe(a) * volA + _fHe(b) * volB) / total,
  );
}

/// The fill gases to use for [target], in fill order.
///
/// The configured order is a fill sequence, not a fixed set of roles: the
/// default is O2 -> helium -> air so that the compressor tops off last, which
/// is how a fill station actually works. A helium-free target therefore has to
/// skip the helium source rather than blend with it, otherwise it would report
/// a nitrox mix while producing a trimix.
List<GasMix> _selectFillGases(GasMix target, List<GasMix> available) {
  if (!_isHeliumFree(target)) return available;
  final heliumFree = available.where(_isHeliumFree).toList();
  if (heliumFree.length < 2) {
    throw const BlendException(BlendError.insufficientFillGases);
  }
  return heliumFree.take(2).toList();
}

/// Surface volume of each gas in [gases] needed to turn [startVol] of [start]
/// into [targetVol] of [target], per litre of cylinder volume.
///
/// Amounts may come back negative: that means the cylinder already holds gas
/// the target cannot accommodate, which the caller turns into drain guidance.
/// Throws only when the gas set cannot produce the target at any amount.
List<double> _solveTops({
  required GasMix start,
  required double startVol,
  required GasMix target,
  required double targetVol,
  required List<GasMix> gases,
}) {
  if (gases.length == 3) {
    final g1 = gases[0];
    final g2 = gases[1];
    final g3 = gases[2];

    final det =
        _fHe(g3) * _fN2(g2) * _fO2(g1) -
        _fHe(g2) * _fN2(g3) * _fO2(g1) -
        _fHe(g3) * _fN2(g1) * _fO2(g2) +
        _fHe(g1) * _fN2(g3) * _fO2(g2) +
        _fHe(g2) * _fN2(g1) * _fO2(g3) -
        _fHe(g1) * _fN2(g2) * _fO2(g3);
    if (det.abs() < 1e-10) {
      throw const BlendException(BlendError.linearlyDependentGases);
    }

    final df = [
      _fHe(target) * targetVol - _fHe(start) * startVol,
      _fN2(target) * targetVol - _fN2(start) * startVol,
      _fO2(target) * targetVol - _fO2(start) * startVol,
    ];

    return [
      ((_fN2(g3) * _fO2(g2) - _fN2(g2) * _fO2(g3)) * df[0] +
              (_fHe(g2) * _fO2(g3) - _fHe(g3) * _fO2(g2)) * df[1] +
              (_fHe(g3) * _fN2(g2) - _fHe(g2) * _fN2(g3)) * df[2]) /
          det,
      ((_fN2(g1) * _fO2(g3) - _fN2(g3) * _fO2(g1)) * df[0] +
              (_fHe(g3) * _fO2(g1) - _fHe(g1) * _fO2(g3)) * df[1] +
              (_fHe(g1) * _fN2(g3) - _fHe(g3) * _fN2(g1)) * df[2]) /
          det,
      ((_fN2(g2) * _fO2(g1) - _fN2(g1) * _fO2(g2)) * df[0] +
              (_fHe(g1) * _fO2(g2) - _fHe(g2) * _fO2(g1)) * df[1] +
              (_fHe(g2) * _fN2(g1) - _fHe(g1) * _fN2(g2)) * df[2]) /
          det,
    ];
  }

  final g1 = gases[0];
  final g2 = gases[1];
  if ((_fO2(g1) - _fO2(g2)).abs() < 0.001) {
    throw const BlendException(BlendError.identicalNitroxGases);
  }
  final top1 =
      (_fO2(g2) - _fO2(target)) / (_fO2(g2) - _fO2(g1)) * targetVol -
      (_fO2(g2) - _fO2(start)) / (_fO2(g2) - _fO2(g1)) * startVol;
  return [top1, (targetVol - startVol) - top1];
}

/// The largest starting volume that still blends, or null when even an empty
/// cylinder cannot produce the target from these gases.
///
/// Every fill amount is affine in the starting volume, so the feasible set is
/// an interval. When an empty cylinder is feasible that interval starts at
/// zero, which makes feasibility monotonic and a bisection exact.
double? _largestFeasibleStartVolume({
  required GasMix start,
  required double startVol,
  required GasMix target,
  required double targetVol,
  required List<GasMix> gases,
}) {
  bool feasible(double v) {
    try {
      return _solveTops(
        start: start,
        startVol: v,
        target: target,
        targetVol: targetVol,
        gases: gases,
      ).every((t) => t >= -_volumeTolerance);
    } on BlendException {
      return false;
    }
  }

  if (!feasible(0)) return null;

  var lo = 0.0;
  var hi = startVol;
  for (var i = 0; i < 50; i++) {
    final mid = (lo + hi) / 2;
    if (feasible(mid)) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return lo;
}

/// Compute the fill procedure to reach the target fill. Throws
/// [BlendException] when the requested blend is not achievable.
BlendResult computeBlend(GasBlenderInputs inputs) {
  final pi = inputs.startPressureBar;
  final pf = inputs.targetPressureBar;
  final gasI = inputs.start;
  final gasF = inputs.target;

  if (pf <= pi) {
    throw const BlendException(BlendError.targetPressureNotHigher);
  }
  _validateMix(gasI);
  _validateMix(gasF);
  _validateMix(inputs.fillGas1);
  _validateMix(inputs.fillGas2);
  _validateMix(inputs.fillGas3);

  // Topping up dilutes helium; it never removes it. Solving the O2 balance
  // alone would report the requested nitrox while leaving helium in the
  // cylinder, and an O2 analyser would confirm the wrong label.
  if (_isHeliumFree(gasF) && !_isHeliumFree(gasI)) {
    throw const BlendException(BlendError.cannotRemoveHelium);
  }

  final gases = _selectFillGases(gasF, [
    inputs.fillGas1,
    inputs.fillGas2,
    inputs.fillGas3,
  ]);

  final iVol = normalVolume(pi, gasI);
  final fVol = normalVolume(pf, gasF);

  final tops = _solveTops(
    start: gasI,
    startVol: iVol,
    target: gasF,
    targetVol: fVol,
    gases: gases,
  );

  if (tops.any((t) => t < -_volumeTolerance)) {
    final drainVol = _largestFeasibleStartVolume(
      start: gasI,
      startVol: iVol,
      target: gasF,
      targetVol: fVol,
      gases: gases,
    );
    throw BlendException(
      BlendError.negativeAmountRequired,
      drainToBar: drainVol == null ? null : pressureForVolume(gasI, drainVol),
    );
  }

  final steps = <BlendStep>[
    BlendStep(
      fillGas: null,
      pressureBar: pi,
      resultingMix: gasI,
      addedVolumePerLiter: null,
    ),
  ];

  var mix = gasI;
  var vol = iVol;
  for (var i = 0; i < gases.length; i++) {
    final top = tops[i];
    // A gas the blend does not need is left out rather than listed as a fill
    // to the pressure already in the cylinder.
    if (top.abs() < _volumeTolerance) continue;
    mix = _blend(mix, vol, gases[i], top);
    vol += top;
    steps.add(
      BlendStep(
        fillGas: gases[i],
        pressureBar: pressureForVolume(mix, vol),
        resultingMix: mix,
        addedVolumePerLiter: top,
      ),
    );
  }

  // The requested pressure is what the blender fills to; use it verbatim
  // rather than the fixed-point iteration's approximation of it.
  if (steps.length > 1) {
    final last = steps.removeLast();
    steps.add(
      BlendStep(
        fillGas: last.fillGas,
        pressureBar: pf,
        resultingMix: last.resultingMix,
        addedVolumePerLiter: last.addedVolumePerLiter,
      ),
    );
  }

  // Never report a mix that was not computed from the gas actually added.
  if ((mix.o2 - gasF.o2).abs() > 0.01 || (mix.he - gasF.he).abs() > 0.01) {
    throw const BlendException(BlendError.targetNotReached);
  }

  return BlendResult(steps: steps);
}
