'use strict';

exports = module.exports = {
    backup: backup,
    restore: restore,
    copyBackup: copyBackup,
    removeBackup: removeBackup,

    getDownloadStream: getDownloadStream,

    backupDone: backupDone,

    testConfig: testConfig
};

var assert = require('assert'),
    async = require('async'),
    BackupsError = require('../backups.js').BackupsError,
    crypto = require('crypto'),
    config = require('../config.js'),
    debug = require('debug')('box:storage/filesystem'),
    fs = require('fs'),
    mkdirp = require('mkdirp'),
    once = require('once'),
    path = require('path'),
    safe = require('safetydance'),
    spawn = require('child_process').spawn,
    tar = require('tar-fs'),
    zlib = require('zlib');

var FALLBACK_BACKUP_FOLDER = '/var/backups';
var FILE_TYPE = '.tar.gz.enc';
var BACKUP_USER = config.TEST ? process.env.USER : 'yellowtent';

// internal only
function getBackupFilePath(apiConfig, backupId) {
    assert.strictEqual(typeof apiConfig, 'object');
    assert.strictEqual(typeof backupId, 'string');

    return path.join(apiConfig.backupFolder || FALLBACK_BACKUP_FOLDER, backupId.endsWith(FILE_TYPE) ? backupId : backupId+FILE_TYPE);
}

// storage api
function backup(apiConfig, backupId, sourceDirectories, callback) {
    assert.strictEqual(typeof apiConfig, 'object');
    assert.strictEqual(typeof backupId, 'string');
    assert(Array.isArray(sourceDirectories));
    assert.strictEqual(typeof callback, 'function');

    callback = once(callback);

    var backupFilePath = getBackupFilePath(apiConfig, backupId);

    debug('[%s] backup: %j -> %s', backupId, sourceDirectories, backupFilePath);

    mkdirp(path.dirname(backupFilePath), function (error) {
        if (error) return callback(new BackupsError(BackupsError.EXTERNAL_ERROR, error.message));

        var pack = tar.pack('/', {
            entries: sourceDirectories.map(function (m) { return m.source; }),
            map: function(header) {
                sourceDirectories.forEach(function (m) {
                    header.name = header.name.replace(new RegExp('^' + m.source + '(/?)'), m.destination + '$1');
                });
                return header;
            }
        });

        var gzip = zlib.createGzip({});
        var encrypt = crypto.createCipher('aes-256-cbc', apiConfig.key || '');
        var fileStream = fs.createWriteStream(backupFilePath);

        pack.on('error', function (error) {
            console.error('[%s] backup: tar stream error.', backupId, error);
            callback(new BackupsError(BackupsError.EXTERNAL_ERROR, error.message));
        });

        gzip.on('error', function (error) {
            console.error('[%s] backup: gzip stream error.', backupId, error);
            callback(new BackupsError(BackupsError.EXTERNAL_ERROR, error.message));
        });

        encrypt.on('error', function (error) {
            console.error('[%s] backup: encrypt stream error.', backupId, error);
            callback(new BackupsError(BackupsError.EXTERNAL_ERROR, error.message));
        });

        fileStream.on('error', function (error) {
            console.error('[%s] backup: out stream error.', backupId, error);
            callback(new BackupsError(BackupsError.EXTERNAL_ERROR, error.message));
        });

        fileStream.on('close', function () {
            debug('[%s] backup: changing ownership.', backupId);

            if (!safe.child_process.execSync('chown -R ' + BACKUP_USER + ':' + BACKUP_USER + ' ' + path.dirname(backupFilePath))) return callback(new BackupsError(BackupsError.INTERNAL_ERROR, safe.error.message));

            debug('[%s] backup: done.', backupId);

            callback(null);
        });

        pack.pipe(gzip).pipe(encrypt).pipe(fileStream);
    });
}

function restore(apiConfig, backupId, destination, callback) {
    assert.strictEqual(typeof apiConfig, 'object');
    assert.strictEqual(typeof backupId, 'string');
    assert.strictEqual(typeof destination, 'string');
    assert.strictEqual(typeof callback, 'function');

    var isOldFormat = backupId.endsWith('.tar.gz');
    var sourceFilePath = isOldFormat ? path.join(apiConfig.backupFolder || FALLBACK_BACKUP_FOLDER, backupId) : getBackupFilePath(apiConfig, backupId);

    debug('[%s] restore: %s -> %s', backupId, sourceFilePath, destination);

    if (!fs.existsSync(sourceFilePath)) return callback(new BackupsError(BackupsError.NOT_FOUND, 'backup file does not exist'));

    mkdirp(destination, function (error) {
        if (error) return callback(new BackupsError(BackupsError.EXTERNAL_ERROR, error.message));

        var fileStream = fs.createReadStream(sourceFilePath);
        var decrypt;

        if (isOldFormat) {
            let args = ['aes-256-cbc', '-d', '-pass', 'pass:' + apiConfig.key];
            decrypt = spawn('openssl', args, { stdio: [ 'pipe', 'pipe', process.stderr ]});
        } else {
            decrypt = crypto.createDecipher('aes-256-cbc', apiConfig.key || '');
        }

        var gunzip = zlib.createGunzip({});
        var extract = tar.extract(destination);

        fileStream.on('error', function (error) {
            console.error('[%s] restore: file stream error.', error);
            callback(new BackupsError(BackupsError.EXTERNAL_ERROR, error.message));
        });

        decrypt.on('error', function (error) {
            console.error('[%s] restore: decrypt stream error.', error);
            callback(new BackupsError(BackupsError.EXTERNAL_ERROR, error.message));
        });

        gunzip.on('error', function (error) {
            console.error('[%s] restore: gunzip stream error.', error);
            callback(new BackupsError(BackupsError.EXTERNAL_ERROR, error.message));
        });

        extract.on('error', function (error) {
            console.error('[%s] restore: extract stream error.', error);
            callback(new BackupsError(BackupsError.EXTERNAL_ERROR, error.message));
        });

        extract.on('finish', function () {
            debug('[%s] restore: %s done.', backupId);
            callback(null);
        });

        if (isOldFormat) {
            fileStream.pipe(decrypt.stdin);
            decrypt.stdout.pipe(gunzip).pipe(extract);
        } else {
            fileStream.pipe(decrypt).pipe(gunzip).pipe(extract);
        }
    });
}

function copyBackup(apiConfig, oldBackupId, newBackupId, callback) {
    assert.strictEqual(typeof apiConfig, 'object');
    assert.strictEqual(typeof oldBackupId, 'string');
    assert.strictEqual(typeof newBackupId, 'string');
    assert.strictEqual(typeof callback, 'function');

    callback = once(callback);

    var oldFilePath = getBackupFilePath(apiConfig, oldBackupId);
    var newFilePath = getBackupFilePath(apiConfig, newBackupId);

    debug('copyBackup: %s -> %s', oldFilePath, newFilePath);

    mkdirp(path.dirname(newFilePath), function (error) {
        if (error) return callback(new BackupsError(BackupsError.EXTERNAL_ERROR, error.message));

        var readStream = fs.createReadStream(oldFilePath);
        var writeStream = fs.createWriteStream(newFilePath);

        readStream.on('error', function (error) {
            console.error('copyBackup: read stream error.', error);
            callback(new BackupsError(BackupsError.EXTERNAL_ERROR, error.message));
        });

        writeStream.on('error', function (error) {
            console.error('copyBackup: write stream error.', error);
            callback(new BackupsError(BackupsError.EXTERNAL_ERROR, error.message));
        });

        writeStream.on('close', function () {
            if (!safe.child_process.execSync('chown -R ' + BACKUP_USER + ':' + BACKUP_USER + ' ' + path.dirname(newFilePath))) return callback(new BackupsError(BackupsError.INTERNAL_ERROR, safe.error.message));

            callback();
        });

        readStream.pipe(writeStream);
    });
}

function removeBackup(apiConfig, backupId, appBackupIds, callback) {
    assert.strictEqual(typeof apiConfig, 'object');
    assert.strictEqual(typeof backupId, 'string');
    assert(Array.isArray(appBackupIds));
    assert.strictEqual(typeof callback, 'function');

    async.each([backupId].concat(appBackupIds), function (id, callback) {
        var filePath = getBackupFilePath(apiConfig, id);

        fs.unlink(filePath, function (error) {
            if (error) console.error('Unable to remove %s. Not fatal.', filePath, error);
            callback();
        });
    }, callback);
}

function getDownloadStream(apiConfig, backupId, callback) {
    assert.strictEqual(typeof apiConfig, 'object');
    assert.strictEqual(typeof backupId, 'string');
    assert.strictEqual(typeof callback, 'function');

    var backupFilePath = getBackupFilePath(apiConfig, backupId);

    debug('[%s] getDownloadStream: %s %s', backupId, backupId, backupFilePath);

    if (!fs.existsSync(backupFilePath)) return callback(new BackupsError(BackupsError.NOT_FOUND, 'backup file does not exist'));

    var stream = fs.createReadStream(backupFilePath);
    callback(null, stream);
}

function testConfig(apiConfig, callback) {
    assert.strictEqual(typeof apiConfig, 'object');
    assert.strictEqual(typeof callback, 'function');

    if ('backupFolder' in apiConfig && typeof apiConfig.backupFolder !== 'string') return callback(new BackupsError(BackupsError.BAD_FIELD, 'backupFolder must be string'));

    // default value will be used
    if (!apiConfig.backupFolder) return callback();

    fs.stat(apiConfig.backupFolder, function (error, result) {
        if (error) {
            debug('testConfig: %s', apiConfig.backupFolder, error);
            return callback(new BackupsError(BackupsError.BAD_FIELD, 'Directory does not exist or cannot be accessed'));
        }

        if (!result.isDirectory()) return callback(new BackupsError(BackupsError.BAD_FIELD, 'Backup location is not a directory'));

        callback(null);
    });
}

function backupDone(backupId, appBackupIds, callback) {
    assert.strictEqual(typeof backupId, 'string');
    assert(Array.isArray(appBackupIds));
    assert.strictEqual(typeof callback, 'function');

    callback();
}
