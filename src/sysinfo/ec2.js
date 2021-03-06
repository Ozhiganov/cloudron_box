'use strict';

exports = module.exports = {
    getPublicIp: getPublicIp
};

var assert = require('assert'),
    superagent = require('superagent'),
    SysInfoError = require('../sysinfo.js').SysInfoError,
    util = require('util');

function getPublicIp(callback) {
    assert.strictEqual(typeof callback, 'function');

    superagent.get('http://169.254.169.254/latest/meta-data/public-ipv4').timeout(30 * 1000).end(function (error, result) {
        if (error) return callback(new SysInfoError(SysInfoError.INTERNAL_ERROR, error.status ? 'Request failed: ' + error.status : 'Network failure'));
        if (result.statusCode !== 200) return callback(new SysInfoError(SysInfoError.EXTERNAL_ERROR, util.format('%s %j', result.status, result.body)));

        callback(null, result.text);
    });
}
