// SPDX-License-Identifier: AGPL-3.0
//
// Cross-app donor surfaces — link out, never duplicate full stacks in Talk.

class WelcomeDonorLinks {
  WelcomeDonorLinks._();

  static Uri get lifestyle => Uri.parse('https://lifestyle.interactpak.com');
  static Uri get lifestyleBookings =>
      Uri.parse('https://lifestyle.interactpak.com/bookings');
  // /goals has no page yet on the Lifestyle app, so it 404s. Point at the
  // Lifestyle home (which renders) until a dedicated goals page ships there.
  static Uri get lifestyleGoals =>
      Uri.parse('https://lifestyle.interactpak.com');
  static Uri get execOs => Uri.parse('https://execute.interactpak.com');
  static Uri get interactPro => Uri.parse('interactpro://open?path=/notes');
  static Uri get zeka => Uri.parse('https://qurbanisahulat.com/zeka');
}
