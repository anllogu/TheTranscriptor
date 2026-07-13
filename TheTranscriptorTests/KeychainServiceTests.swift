import XCTest
@testable import TheTranscriptor

final class KeychainServiceTests: XCTestCase {
    var keychainService: KeychainService!
    let testService = "com.allosa.TheTranscriptor.test"

    override func setUp() {
        super.setUp()
        keychainService = KeychainService(service: testService)
        // Clean up any existing test data
        keychainService.deleteToken()
    }

    override func tearDown() {
        // Clean up test data
        keychainService.deleteToken()
        super.tearDown()
    }

    func testSetAndRetrieveToken() throws {
        let testToken = "hf_test12345abcde"

        try keychainService.setToken(testToken)
        let retrievedToken = keychainService.token()

        XCTAssertEqual(retrievedToken, testToken)
    }

    func testTokenReturnsNilWhenNotSet() {
        let token = keychainService.token()
        XCTAssertNil(token)
    }

    func testUpdateToken() throws {
        let firstToken = "hf_first"
        let secondToken = "hf_second"

        try keychainService.setToken(firstToken)
        var retrievedToken = keychainService.token()
        XCTAssertEqual(retrievedToken, firstToken)

        try keychainService.setToken(secondToken)
        retrievedToken = keychainService.token()
        XCTAssertEqual(retrievedToken, secondToken)
    }

    func testDeleteToken() throws {
        let testToken = "hf_testtoken"

        try keychainService.setToken(testToken)
        var retrievedToken = keychainService.token()
        XCTAssertEqual(retrievedToken, testToken)

        keychainService.deleteToken()
        retrievedToken = keychainService.token()
        XCTAssertNil(retrievedToken)
    }

    func testEmptyStringToken() throws {
        try keychainService.setToken("")
        let retrievedToken = keychainService.token()
        XCTAssertEqual(retrievedToken, "")
    }

    func testLongToken() throws {
        let longToken = String(repeating: "a", count: 1000)

        try keychainService.setToken(longToken)
        let retrievedToken = keychainService.token()

        XCTAssertEqual(retrievedToken, longToken)
    }

    func testUnicodeToken() throws {
        let unicodeToken = "hf_test_🔐_unicode_éàü"

        try keychainService.setToken(unicodeToken)
        let retrievedToken = keychainService.token()

        XCTAssertEqual(retrievedToken, unicodeToken)
    }
}
