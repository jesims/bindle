module.exports = config => config.set({
  basePath: 'target/karma',
  files: ['test.js'],
  browsers: ['JesiChromiumHeadless'],
  browserDisconnectTimeout: 10000,
  browserDisconnectTolerance: 5,
  browserNoActivityTimeout: 60000,
  customLaunchers: {
    JesiChromiumHeadless: {
      base: 'ChromiumHeadless',
      displayName: 'ChromiumHeadless',
      flags: [
        '--disable-dev-shm-usage',
        '--disable-gpu',
        '--disk-cache-size=0',
        '--headless'
      ]
    }
  },
  frameworks: ['cljs-test'],
  plugins: ['karma-cljs-test', 'karma-chrome-launcher'],
  colors: true,
  logLevel: config.LOG_INFO,
  client: {
    args: ['shadow.test.karma.init'],
    singleRun: true
  },
  singleRun: true,
  retryLimit: 0
})
