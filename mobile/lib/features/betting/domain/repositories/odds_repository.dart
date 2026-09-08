import '../entities/fixture.dart';

/// Contract for the betting data layer (Clean Architecture interface).
abstract class OddsRepository {
  /// Enabled fixtures visible on the betting screens.
  Future<List<FixtureTeam>> fetchEnabledFixtures();

  /// Places a Body (single) bet; returns the backend confirmation.
  Future<BetPlacement> placeBodyBet({
    required int fixtureId,
    required SelectionPick pick,
    required double stake,
    required String handicap,
  });

  /// Places a Maung (mix parlay) ticket across multiple selections.
  Future<BetPlacement> placeMaungBet({
    required List<SelectionInput> selections,
    required double stake,
  });
}