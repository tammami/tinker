import DBCore
import DBSQL
import XCTest

@testable import DBGrid

/// A foreign key the paste target cannot honour is taken out of the server's own DDL,
/// and nothing else is.
final class ForeignKeyStripTests: XCTestCase {
    func testMySQLKeyOnTheLastLineTakesTheDanglingCommaWithIt() {
        let ddl = """
            CREATE TABLE `asset_bidang` (
              `id` varchar(5) NOT NULL,
              `id_golongan` varchar(2) NOT NULL,
              PRIMARY KEY (`id`) USING BTREE,
              KEY `id_golongan` (`id_golongan`) USING BTREE,
              CONSTRAINT `asset_bidang_ibfk_1` FOREIGN KEY (`id_golongan`) REFERENCES `asset_golongan` (`id`) ON DELETE CASCADE
            ) ENGINE=InnoDB DEFAULT CHARSET=latin1
            """
        let stripped = DatabaseDumper.removingForeignKeys(["asset_bidang_ibfk_1"], from: ddl, dialect: .mysql)
        XCTAssertFalse(stripped.contains("FOREIGN KEY"))
        XCTAssertTrue(stripped.contains("KEY `id_golongan` (`id_golongan`) USING BTREE\n) ENGINE=InnoDB"), stripped)
        XCTAssertTrue(stripped.contains("PRIMARY KEY (`id`) USING BTREE,"), "the lines before keep their commas")
    }

    func testPostgresKeyInTheMiddleKeepsTheOtherConstraints() {
        let ddl = """
            CREATE TABLE "public"."orders" (
                "id" serial,
                "customer_id" integer NOT NULL,
                CONSTRAINT "orders_total_check" CHECK ((total >= (0)::numeric)),
                CONSTRAINT "orders_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES customers(id),
                CONSTRAINT "orders_pkey" PRIMARY KEY (id)
            );
            CREATE INDEX orders_customer_idx ON public.orders USING btree (customer_id);
            """
        let stripped = DatabaseDumper.removingForeignKeys(["orders_customer_id_fkey"], from: ddl, dialect: .postgresql)
        XCTAssertFalse(stripped.contains("FOREIGN KEY"))
        XCTAssertTrue(stripped.contains("CHECK ((total >= (0)::numeric)),\n    CONSTRAINT \"orders_pkey\""), stripped)
        XCTAssertTrue(stripped.contains("CREATE INDEX orders_customer_idx"), "the statements after the table stay")
    }

    func testOnlyTheNamedKeysGo() {
        let ddl = """
            CREATE TABLE `child` (
              `a` int,
              `b` int,
              CONSTRAINT `child_a` FOREIGN KEY (`a`) REFERENCES `kept` (`id`),
              CONSTRAINT `child_b` FOREIGN KEY (`b`) REFERENCES `missing` (`id`)
            ) ENGINE=InnoDB
            """
        let stripped = DatabaseDumper.removingForeignKeys(["child_b"], from: ddl, dialect: .mysql)
        XCTAssertTrue(stripped.contains("CONSTRAINT `child_a` FOREIGN KEY (`a`) REFERENCES `kept` (`id`)\n)"), stripped)
        XCTAssertFalse(stripped.contains("missing"))
        XCTAssertEqual(DatabaseDumper.removingForeignKeys([], from: ddl, dialect: .mysql), ddl)
        XCTAssertEqual(
            DatabaseDumper.removingForeignKeys(["child"], from: ddl, dialect: .mysql), ddl,
            "a name that is only the start of another key's name removes nothing")
    }
}
