module.exports = {
  preset: 'react-native',
  setupFiles: ['./jest.setup.js'],
  moduleNameMapper: {
    '^react-native-haptic-feedback$':
      '<rootDir>/node_modules/react-native-haptic-feedback/src/__mocks__/react-native-haptic-feedback',
    // The library is linked via file:../ — inside its sources react-native
    // would otherwise resolve to the repo root's copy, bypassing our mocks.
    '^react-native$': '<rootDir>/node_modules/react-native',
    '^react-native/(.*)$': '<rootDir>/node_modules/react-native/$1',
    '^react$': '<rootDir>/node_modules/react',
    '^react/(.*)$': '<rootDir>/node_modules/react/$1',
  },
};
