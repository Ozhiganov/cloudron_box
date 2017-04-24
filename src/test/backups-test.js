/* jslint node:true */
/* global it:false */
/* global describe:false */
/* global before:false */
/* global after:false */

'use strict';

var async = require('async'),
    backupdb = require('../backupdb.js'),
    backups = require('../backups.js'),
    database = require('../database'),
    DatabaseError = require('../databaseerror.js'),
    expect = require('expect.js'),
    settings = require('../settings.js');

describe('janitor', function () {
    before(function (done) {
        async.series([
            database.initialize,
            database._clear,
            settings.initialize,
            settings.setBackupConfig.bind(null, {
                provider: 'filesystem',
                key: 'enckey',
                retentionSecs: 1
            })
        ], done);
    });

    after(function (done) {
        async.series([
            settings.uninitialize,
            database._clear
        ], done);
    });

    describe('cleanup', function () {
        this.timeout(20000);

        var BACKUP_0 = {
            id: 'backup-box-0',
            version: '1.0.0',
            type: backupdb.BACKUP_TYPE_BOX,
            dependsOn: [ 'backup-app-00', 'backup-app-01' ],
            restoreConfig: null
        };

        var BACKUP_0_APP_0 = {
            id: 'backup-app-00',
            version: '1.0.0',
            type: backupdb.BACKUP_TYPE_APP,
            dependsOn: [],
            restoreConfig: null
        };

        var BACKUP_0_APP_1 = {
            id: 'backup-app-01',
            version: '1.0.0',
            type: backupdb.BACKUP_TYPE_APP,
            dependsOn: [],
            restoreConfig: null
        };

        var BACKUP_1 = {
            id: 'backup-box-1',
            version: '1.0.0',
            type: backupdb.BACKUP_TYPE_BOX,
            dependsOn: [ 'backup-app-10', 'backup-app-11' ],
            restoreConfig: null
        };

        var BACKUP_1_APP_0 = {
            id: 'backup-app-10',
            version: '1.0.0',
            type: backupdb.BACKUP_TYPE_APP,
            dependsOn: [],
            restoreConfig: null
        };

        var BACKUP_1_APP_1 = {
            id: 'backup-app-11',
            version: '1.0.0',
            type: backupdb.BACKUP_TYPE_APP,
            dependsOn: [],
            restoreConfig: null
        };

        it('succeeds without backups', function (done) {
            backups.cleanup(done);
        });

        it('succeeds with box backups, keeps latest', function (done) {
            async.eachSeries([[ BACKUP_0, BACKUP_0_APP_0, BACKUP_0_APP_1 ], [ BACKUP_1, BACKUP_1_APP_0, BACKUP_1_APP_1 ]], function (backup, callback) {
                // space out backups
                setTimeout(function () {
                    async.each(backup, backupdb.add, callback);
                }, 2000);
            }, function (error) {
                expect(error).to.not.be.ok();

                backups.cleanup(function (error) {
                    expect(error).to.not.be.ok();

                    backups.getPaged(1, 1000, function (error, result) {
                        expect(error).to.not.be.ok();
                        expect(result.length).to.equal(1);
                        expect(result[0].id).to.equal(BACKUP_1.id);

                        // check that app backups are gone as well
                        backupdb.get(BACKUP_0_APP_0.id, function (error) {
                            expect(error).to.be.a(DatabaseError);
                            expect(error.reason).to.equal(DatabaseError.NOT_FOUND);

                            done();
                        });
                    });
                });
            });
        });

        it('does not remove expired backups if only one left', function (done) {
            backups.cleanup(function (error) {
                expect(error).to.not.be.ok();

                backups.getPaged(1, 1000, function (error, result) {
                    expect(error).to.not.be.ok();
                    expect(result.length).to.equal(1);
                    expect(result[0].id).to.equal(BACKUP_1.id);

                    done();
                });
            });
        });
    });
});
