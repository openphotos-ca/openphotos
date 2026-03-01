/** @type {import('next').NextConfig} */
const path = require('path');
const ENABLE_EE = process.env.NEXT_PUBLIC_ENABLE_EE === '1' || process.env.NEXT_PUBLIC_ENABLE_EE === 'true';

const nextConfig = {
  output: 'export',
  images: { unoptimized: true },
  trailingSlash: true,
  experimental: { externalDir: true },
  webpack: (config) => {
    // Enable WebAssembly for argon2-browser and any future WASM deps
    config.experiments = {
      ...(config.experiments || {}),
      asyncWebAssembly: true,
    };
    // Treat .wasm files as async WebAssembly modules
    config.module.rules = config.module.rules || [];
    config.module.rules.push({
      test: /\.wasm$/,
      type: 'webassembly/async',
    });
    config.resolve.alias = config.resolve.alias || {};
    // Ensure external EE modules resolve icons from this app's node_modules
    // This avoids resolution issues when importing from ../ee/web/*
    config.resolve.alias['lucide-react'] = path.resolve(__dirname, 'node_modules', 'lucide-react');
    // Some EE components import optional deps that live in this app
    // Make sure they resolve correctly when sourced from outside the app dir
    config.resolve.alias['qrcode'] = path.resolve(__dirname, 'node_modules', 'qrcode');
    config.resolve.alias['tus-js-client'] = path.resolve(__dirname, 'node_modules', 'tus-js-client');
    if (ENABLE_EE) {
      const eePath = path.resolve(__dirname, '..', 'ee', 'web');
      console.log('[next.config] EE enabled: alias @ee ->', eePath);
      config.resolve.alias['@ee'] = eePath;
    } else {
      const stubPath = path.resolve(__dirname, 'lib', 'ee_stub');
      console.log('[next.config] EE disabled: alias @ee ->', stubPath);
      config.resolve.alias['@ee'] = stubPath;
    }
    return config;
  },
};

module.exports = nextConfig;
