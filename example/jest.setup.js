// The library's TurboModule is not available in jest; back it with mocks the
// same way the library's own setupTests.js does.
jest.mock('react-native/Libraries/TurboModule/TurboModuleRegistry', () => {
  const actual = jest.requireActual(
    'react-native/Libraries/TurboModule/TurboModuleRegistry',
  );
  const RNHapticFeedback = {
    trigger: jest.fn(),
    stop: jest.fn(),
    isSupported: jest.fn().mockReturnValue(true),
    triggerPattern: jest.fn(),
    playAHAP: jest.fn().mockResolvedValue(undefined),
    getSystemHapticStatus: jest
      .fn()
      .mockResolvedValue({ vibrationEnabled: true, ringerMode: 'normal' }),
  };
  return {
    ...actual,
    get: name =>
      name === 'RNHapticFeedback' ? RNHapticFeedback : actual.get(name),
    getEnforcing: name =>
      name === 'RNHapticFeedback'
        ? RNHapticFeedback
        : actual.getEnforcing(name),
  };
});

// AsyncStorage ships a jest mock but does not wire it up automatically.
jest.mock('@react-native-async-storage/async-storage', () =>
  require('@react-native-async-storage/async-storage/jest/async-storage-mock'),
);

// react-native-iap is backed by Nitro native modules that do not exist in jest.
jest.mock('react-native-iap', () => ({
  ErrorCode: { UserCancelled: 'user-cancelled' },
  useIAP: () => ({
    connected: false,
    products: [],
    availablePurchases: [],
    fetchProducts: jest.fn(),
    requestPurchase: jest.fn(),
    finishTransaction: jest.fn(),
    getAvailablePurchases: jest.fn(),
  }),
}));
