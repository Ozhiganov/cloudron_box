'use strict';

var dbm = dbm || require('db-migrate');

function LOG_ERROR(error, next) {
    if (error) console.error(error);
    next();
}

exports.up = function(db, callback) {
    async.series([
        db.runSql.bind(db, 'ALTER TABLE mailboxes ADD COLUMN ownerId VARCHAR(128)'),
        db.runSql.bind(db, 'ALTER TABLE mailboxes ADD COLUMN ownerType VARCHAR(16)'),
        db.runSql.bind(db, 'START TRANSACTION;'),
        function addGroupMailboxes(done) {
            console.log('Importing group mailboxes');

            db.all('SELECT id, name FROM groups', function (error, results) {
                if (error) return done(error);

                async.eachSeries(results, function (g, next) {
                    db.runSql('INSERT INTO mailboxes (ownerId, ownerType, name) VALUES (?, ?, ?)', [ g.id, 'group', g.name ], LOG_ERROR);
                }, done);
            });
        },
        function addAppMailboxes(done) {
            console.log('Importing app mail boxes');

            db.all('SELECT id, location, manifestJson FROM apps', function (error, results) {
                if (error) return done(error);

                async.eachSeries(results, function (a, next) {
                    var manifest = JSON.parse(a.manifestJson);
                    if (!manifest.addons['sendmail'] && !manifest.addons['recvmail']) return next();

                    var mailboxName = (a.location ? a.location : manifest.title.replace(/[^a-zA-Z0-9]/g, '')) + '.app';
                    db.runSql('INSERT INTO mailboxes (ownerId, ownerType, name) VALUES (?, ?, ?)', [ a.id, 'app', mailboxName ], LOG_ERROR);
                }, done);
            });
        },
        function setUserMailboxOwnerIds(done) {
            console.log('Setting owner id of user mailboxes and aliases');

            db.all('SELECT id, username FROM users', function (error, results) {
                if (error) return done(error);

                async.eachSeries(results, function (u,  next) {
                    if (!u.username) return next();

                    db.runSql('UPDATE mailboxes SET ownerId = ?, ownerType = ? WHERE name = ? OR targetAlias = ?', [ u.id, 'user', u.username, u.username ], LOG_ERROR);
                }, done);
            });
        },
        db.runSql.bind(db, 'COMMIT'),
        db.runSql.bind(db, 'ALTER TABLE mailboxes MODIFY ownerId VARCHAR(128) NOT NULL'),
        db.runSql.bind(db, 'ALTER TABLE mailboxes MODIFY ownerType VARCHAR(128) NOT NULL'),
    ], callback);
};

exports.down = function(db, callback) {
    db.runSql('ALTER TABLE mailboxes DROP COLUMN ownerId', function (error) {
        if (error) console.error(error);

        db.runSql('ALTER TABLE mailboxes DROP COLUMN ownerType', function (error) {
            if (error) console.error(error);
            callback(error);
        });
    });
};

