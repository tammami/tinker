import DBCore
import XCTest

@testable import DBSQL

final class UserOperationsTests: XCTestCase {
    func testCreateOnPostgresQuotesEverythingAndGrantsOnPublic() throws {
        let request = UserRequest(
            name: "report er", password: "p'ass", canCreateDatabase: true,
            database: "shop", privileges: [.select, .insert]
        )
        XCTAssertEqual(
            try UserOperations.create(request, dialect: .postgresql),
            [
                #"CREATE ROLE "report er" LOGIN CREATEDB PASSWORD 'p''ass'"#,
                #"GRANT CONNECT ON DATABASE "shop" TO "report er""#,
                #"GRANT USAGE ON SCHEMA public TO "report er""#,
                #"GRANT INSERT, SELECT ON ALL TABLES IN SCHEMA public TO "report er""#,
                #"ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT INSERT, SELECT ON TABLES TO "report er""#,
            ])
    }

    func testCreateOnMySQLUsesAccountStrings() throws {
        let request = UserRequest(
            name: "app", host: "10.0.%", password: "s3cret", database: "shop", privileges: [.all], grantOption: true
        )
        XCTAssertEqual(
            try UserOperations.create(request, dialect: .mysql),
            [
                "CREATE USER 'app'@'10.0.%' IDENTIFIED BY 's3cret'",
                "GRANT ALL PRIVILEGES ON `shop`.* TO 'app'@'10.0.%' WITH GRANT OPTION",
            ])
        let root = UserRequest(name: "admin", host: "localhost", password: "x", isSuperuser: true)
        XCTAssertEqual(
            try UserOperations.create(root, dialect: .mysql).last,
            "GRANT ALL PRIVILEGES ON *.* TO 'admin'@'localhost' WITH GRANT OPTION")
    }

    func testAlterAndDrop() throws {
        var request = UserRequest(name: "app", host: "%", password: "new", isSuperuser: false)
        XCTAssertEqual(try UserOperations.alter(request, dialect: .mysql), ["ALTER USER 'app'@'%' IDENTIFIED BY 'new'"])
        request.password = nil
        XCTAssertEqual(
            try UserOperations.alter(request, dialect: .mysql), [], "nothing to change without a password or grants")
        XCTAssertEqual(
            try UserOperations.alter(UserRequest(name: "app", password: "new", canLogin: false), dialect: .postgresql),
            [#"ALTER ROLE "app" NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD 'new'"#]
        )
        XCTAssertEqual(UserOperations.drop(request, dialect: .mysql), "DROP USER 'app'@'%'")
        XCTAssertEqual(UserOperations.drop(request, dialect: .postgresql), #"DROP ROLE "app""#)
    }

    func testRefusesAnEmptyNameOrPassword() {
        XCTAssertThrowsError(try UserOperations.create(UserRequest(name: " ", password: "x"), dialect: .mysql))
        XCTAssertThrowsError(try UserOperations.create(UserRequest(name: "a", password: ""), dialect: .postgresql))
    }
}
