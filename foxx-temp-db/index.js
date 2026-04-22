'use strict';

const createRouter = require('@arangodb/foxx/router');
const { db } = require('@arangodb');
const users = require('@arangodb/users');
const tasks = require('@arangodb/tasks');

const router = createRouter();
module.context.use(router);

const ADMIN_TOKEN = process.env.ARANGO_ADMIN_TOKEN || 'arango_token';
const REGISTRY = 'temp_dbs';

function rand(prefix, len) {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  let s = '';
  for (let i = 0; i < len; i++) {
    s += chars[Math.floor(Math.random() * chars.length)];
  }
  return prefix + s;
}

function checkAdmin(req, res) {
  const auth = (req.headers['authorization'] || '').trim();

  if (!auth.startsWith('Bearer ')) {
    res.throw(401, 'Missing Bearer token');
  }

  const token = auth.slice(7);

  if (token !== ADMIN_TOKEN) {
    res.throw(401, 'Invalid admin token');
  }
}

function getRegistry() {
  let col = db._collection(REGISTRY);
  if (!col) {
    col = db._createDocumentCollection(REGISTRY);
  }
  return col;
}

router.get('/create_temp_db', (req, res) => {
  checkAdmin(req, res);

  const dbName = rand('TEMP_', 12);
  const username = rand('U_', 8);
  const password = rand('', 12);

  let ttl = 600;

  if (req.query && req.query.ttl !== undefined) {
    const parsed = parseInt(req.query.ttl, 10);
    if (!isNaN(parsed) && parsed > 0) {
      ttl = parsed;
    }
  }

  const expireAt = Date.now() + ttl * 1000;

  db._createDatabase(dbName);
  users.save(username, password);
  users.grantDatabase(username, dbName, 'rw');

  const col = getRegistry();

  col.save({
    dbName,
    username,
    expireAt
  });

  tasks.register({
    offset: ttl,
    command: `
      const dbName = "${dbName}";
      const username = "${username}";
      const col = require('@arangodb').db._collection('${REGISTRY}');

      try {
        require('@arangodb').db._dropDatabase(dbName);
      } catch (e) {}

      try {
        require('@arangodb/users').remove(username);
      } catch (e) {}

      try {
        const entry = col.firstExample({ dbName });
        if (entry) col.remove(entry);
      } catch (e) {}
    `
  });

  res.send({
    dbName,
    username,
    password,
    ttl
  });
});

router.post('/delete_temp_db', (req, res) => {
  checkAdmin(req, res);
  const body = typeof req.body === 'string'
    ? JSON.parse(req.body)
    : req.body;
  const dbName = body.dbName;

  if (!dbName) {
    res.throw(400, 'dbName is required');
  }

  const col = getRegistry();
  const entry = col.firstExample({ dbName });

  if (!entry) {
    res.throw(404, `Temp DB not found: ${dbName}`);
  }

  try {
    db._dropDatabase(dbName);
  } catch (e) {}

  try {
    users.remove(entry.username);
  } catch (e) {}

  col.remove(entry);

  res.send({
    success: true,
    dbName
  });
});