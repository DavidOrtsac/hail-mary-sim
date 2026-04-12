# Hail Mary: Flight Simulator

A browser-based interstellar flight simulator inspired by Andy Weir's Project Hail Mary. Real orbital mechanics, relativistic physics, and the full Sol-to-Tau-Ceti mission. Built with vanilla HTML5 Canvas, no dependencies.

## Play

Open `index.html` in any modern browser. No install needed.

## What's in here

| File | What |
|------|------|
| `index.html` | The entire game (208 KB) |
| `voyager1-ephem.js` | Voyager 1 trajectory data from JPL Horizons |
| `earth-2k.jpg` | NASA Blue Marble, north pole view |
| `moon-2k.jpg` | NASA LROC lunar surface mosaic |
| `rocket-icon.svg` | Ship sprite |

Total: ~1.4 MB.

## The Science

### What's real
- RK4 (Runge-Kutta 4th order) numerical integration, same method as NASA's GMAT
- N-body gravity from all solar system bodies simultaneously
- JPL Keplerian ephemeris (Standish & Williams J2000.0 elements with century drift rates)
- Truncated Meeus/ELP lunar theory for the Moon (not a simple circle)
- Voyager 1 trajectory from JPL Horizons heliocentric state vectors, Hermite interpolated
- Special relativistic time dilation with proper ship time tracked separately
- Relativistic acceleration correction (parallel component / gamma-cubed, perpendicular / gamma)
- US Standard Atmosphere 1976 with altitude-dependent density layers
- Mach-dependent drag coefficient (subsonic through hypersonic regimes)
- Hypersonic plasma bow shock drag multiplier (10-30x at Mach 10+)
- Sutton-Graves convective heating formula (q ~ rho^0.5 x v^3)
- Patched conics trajectory prediction with SOI transition detection
- Tau Ceti system with real candidate exoplanets from Feng et al. 2017
- Tau Ceti proper motion at 37.2 km/s
- Adrian (Tau Ceti e): 3.93x Earth mass, ~2x diameter, Venus-like 91% CO2 atmosphere at 67 kg/m3
- Stellar radiative heating (inverse square law) with Astrophage shielding
- NASA Blue Marble and LROC Moon textures (public domain)

### What's simplified
- 2D ecliptic projection (no orbital inclinations or out-of-plane maneuvers)
- No J2 oblateness perturbation for Earth
- Keplerian planetary positions (arcminute accuracy, not JPL SPICE-level)
- Truncated lunar series (not the full 600+ term ELP2000-82)
- No relativistic visual effects (Doppler shift, stellar aberration, beaming)
- Atmospheric drag boosted for gameplay feel (real ballistic coefficient would punch through)

### What's creative license
- The ship can enter atmosphere (in the book it never does, it stays in orbit)
- Chain sampler has guidance thrusters (quality of life, not in the book)
- Continuing to fly after beetle launch
- Astrophage becomes infinite after canonical fuel depletes (it's a sim, not a test)

## Controls

| Key | Action |
|-----|--------|
| Arrow Left/Right | Rotate |
| Arrow Up/Down | Throttle |
| Shift | Max throttle |
| Space | Cut throttle |
| B | Full brake (retrograde burn to zero) |
| H | Cycle heading lock (manual/prograde/retrograde/target) |
| J | Deploy/retract xenonite chain |
| P | Centrifuge mode |
| K | Launch beetles |
| Z / X | Warp down / up |
| T | Warp schedule panel |
| C | Camera select |
| M | System map |
| L | Toggle grid |
| ESC | Pause menu (save/load/revert 30s) |
| F5 / F9 | Quicksave / Quickload |
| ? | Mission briefing |

Touch controls appear automatically on mobile.

## Mission

1. Launch from ISS orbit (420 km LEO)
2. Travel 12 light-years to Tau Ceti
3. Orbit Adrian (Tau Ceti e)
4. Deploy the xenonite chain into Adrian's atmosphere
5. Collect 100 Taumoeba samples
6. Centrifuge: breed 82.5 generations of nitrogen-resistant Taumoeba (7 days)
7. Launch the beetles (John, Paul, George, Ringo) carrying the cure

## Credits

Made by David Alfonso Castro.

This is a non-commercial fan work. Project Hail Mary is a novel by Andy Weir. This game is not affiliated with or endorsed by Andy Weir, Penguin Random House, or Amazon/MGM Studios.

NASA imagery: Blue Marble (Suomi-NPP VIIRS), LROC color mosaic. Public domain.
