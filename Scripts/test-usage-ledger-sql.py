#!/usr/bin/env python3
"""用源码中的原始 SQL 验证账本事务；不代替 Swift 类型检查或 App 验收。"""
import concurrent.futures
import hashlib
import json
import os
import pathlib
import re
import sqlite3
import tempfile
import textwrap
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
os.chdir(ROOT)
SOURCE = (ROOT / "Packages/ApelinKit/Sources/ApelinCore/UsageLedger.swift").read_text()
STATEMENTS = []
for match in re.finditer(r'db\.(?:run|rows)\((?:"""\n(.*?)\n\s*"""|"([^"\n]*)")', SOURCE, re.S):
    STATEMENTS.append(textwrap.dedent(match.group(1) or match.group(2)))


def sql(prefix):
    matches = list(dict.fromkeys([s for s in STATEMENTS if s == prefix] or [s for s in STATEMENTS if s.startswith(prefix)]))
    if len(matches) != 1:
        raise AssertionError(f"SQL定位不唯一：{prefix!r}，匹配 {len(matches)} 条")
    return matches[0]


SCHEMA = [s for s in STATEMENTS if s.startswith("CREATE ")]
INSERT_RECEIPT = sql("INSERT OR IGNORE INTO receipts")
UPSERT = sql("INSERT INTO totals(")
DETAIL = sql("INSERT INTO details(")
PRUNE = sql("DELETE FROM details WHERE")
ROLLUPS = sql("SELECT latest,session,project,model,provider,account,host")
RECENT = sql("SELECT payload FROM details")


def connect(path):
    # 使用项目相对路径：roothide 的 Python 与系统 SQLite 对绝对路径的视图不同。
    db = sqlite3.connect(str(path.relative_to(ROOT)), timeout=10, isolation_level=None)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=FULL")
    return db


def insert(db, number, *, session="s", account="a", host="example.com", model="m", day=0):
    receipt = hashlib.sha256(f"{session}:{number}".encode()).hexdigest()
    before = db.total_changes
    db.execute(INSERT_RECEIPT, (receipt,))
    if db.total_changes == before:
        return
    key = hashlib.sha256(json.dumps([day, session, model, account, host]).encode()).hexdigest()
    db.execute(UPSERT, (key, day, session, "项目", model, "openai", account, host,
                       day * 86400 + number, 10, 20, 3, 4))
    db.execute(DETAIL, (receipt, day * 86400 + number, json.dumps({"id": number})))


class UsageSQLTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "build").mkdir(exist_ok=True)
        self.folder = tempfile.TemporaryDirectory(prefix="usage-sql-", dir=ROOT / "build")
        self.path = pathlib.Path(self.folder.name) / "usage.sqlite"
        self.db = connect(self.path)
        for statement in SCHEMA:
            self.db.execute(statement)

    def tearDown(self):
        self.db.close()
        self.folder.cleanup()

    def totals(self):
        return self.db.execute("SELECT SUM(requests),SUM(input),SUM(output),SUM(cache_read),SUM(cache_write) FROM totals").fetchone()

    def test_ten_thousand_requests_keep_totals_and_recent_five_thousand(self):
        self.db.execute("BEGIN IMMEDIATE")
        for i in range(10020):
            insert(self.db, i, account="旧账号" if i == 0 else "a", model="旧模型" if i == 0 else "m")
        self.db.execute(PRUNE, (5000,))
        self.db.execute("COMMIT")
        self.assertEqual(self.totals(), (10020, 100200, 200400, 30060, 40080))
        self.assertEqual(len(self.db.execute(RECENT, (5000,)).fetchall()), 5000)
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM totals WHERE model='旧模型'").fetchone()[0], 1)
        self.assertEqual(sum(r[7] for r in self.db.execute(ROLLUPS)), 10020)
        insert(self.db, 0, account="旧账号", model="旧模型")
        self.assertEqual(self.totals()[0], 10020)

    def test_transaction_failure_rolls_back_receipt_totals_and_detail(self):
        self.db.execute("CREATE TRIGGER fail_detail BEFORE INSERT ON details BEGIN SELECT RAISE(ABORT,'test'); END")
        self.db.execute("BEGIN IMMEDIATE")
        with self.assertRaises(sqlite3.IntegrityError):
            insert(self.db, 1)
        self.db.execute("ROLLBACK")
        for table in ("receipts", "totals", "details"):
            self.assertEqual(self.db.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0], 0)
        self.db.execute("DROP TRIGGER fail_detail")
        insert(self.db, 1)
        self.assertEqual(self.totals()[0], 1)

    def test_clear_keeps_receipts_and_migration_marker(self):
        self.db.execute("INSERT INTO metadata VALUES('legacy_imported','1')")
        insert(self.db, 1)
        self.db.execute("BEGIN IMMEDIATE")
        self.db.execute(sql("DELETE FROM totals"))
        self.db.execute(sql("DELETE FROM details"))
        self.db.execute("COMMIT")
        insert(self.db, 1)
        self.assertEqual(self.totals()[0], None)
        self.assertEqual(self.db.execute("SELECT value FROM metadata WHERE key='legacy_imported'").fetchone()[0], "1")
        insert(self.db, 2)
        self.assertEqual(self.totals()[0], 1)

    def test_account_host_session_day_and_legacy_separation(self):
        for number, options in enumerate(({}, {"account": "b"}, {"host": "other.example"},
                                          {"session": "fork"}, {"day": 1}, {"account": None, "host": None})):
            insert(self.db, number, **options)
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM totals").fetchone()[0], 6)
        self.assertEqual(self.totals()[0], 6)
        self.db.execute(PRUNE, (0,))
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM details").fetchone()[0], 0)
        self.assertEqual(self.totals()[0], 6)

    def test_concurrent_connections_use_transactions_without_lost_updates(self):
        def worker(index):
            db = connect(self.path)
            try:
                db.execute("BEGIN IMMEDIATE")
                insert(db, index % 40)
                db.execute(PRUNE, (3,))
                db.execute("COMMIT")
            finally:
                db.close()
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(worker, range(80)))
        self.assertEqual(self.totals(), (40, 400, 800, 120, 160))
        self.assertEqual(len(self.db.execute(RECENT, (3,)).fetchall()), 3)

    def test_reopen_persists_receipts_and_totals(self):
        insert(self.db, 1)
        self.db.close()
        self.db = connect(self.path)
        insert(self.db, 1)
        self.assertEqual(self.totals()[0], 1)

    def test_integer_overflow_does_not_convert_total_to_real(self):
        insert(self.db, 1)
        self.db.execute("UPDATE totals SET input=9223372036854775807")
        self.db.execute("BEGIN IMMEDIATE")
        with self.assertRaises(sqlite3.IntegrityError):
            insert(self.db, 2)
        self.db.execute("ROLLBACK")
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM receipts").fetchone()[0], 1)
        self.assertEqual(self.db.execute("SELECT input FROM totals").fetchone()[0], 9223372036854775807)


if __name__ == "__main__":
    unittest.main(verbosity=2)
