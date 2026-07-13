const path = require('path');
const { getDefaultConfig, mergeConfig } = require('@react-native/metro-config');

const projectRoot = __dirname;
const libRoot = path.resolve(projectRoot, '..');
const pak = require(path.join(libRoot, 'package.json'));

const escape = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// Dynamically read from the library's peerDependencies so this config stays
// in sync when deps change — no manual list to maintain.
const peerDeps = Object.keys({ ...pak.peerDependencies });

const config = {
  watchFolders: [libRoot],
  resolver: {
    // Fall back to the example's node_modules for anything imported from the
    // library sources (e.g. @babel/runtime helpers injected by the babel
    // transform) — works even when the repo root has no node_modules.
    nodeModulesPaths: [path.join(projectRoot, 'node_modules')],
    // Block the library root's copies of peer deps so Metro never bundles them.
    blockList: peerDeps.map(
      m =>
        new RegExp(`^${escape(path.join(libRoot, 'node_modules', m))}\\/.*$`),
    ),
    // Redirect all peer-dep imports to the example app's node_modules.
    extraNodeModules: peerDeps.reduce((acc, name) => {
      acc[name] = path.join(projectRoot, 'node_modules', name);
      return acc;
    }, {}),
  },
};

module.exports = mergeConfig(getDefaultConfig(__dirname), config);
