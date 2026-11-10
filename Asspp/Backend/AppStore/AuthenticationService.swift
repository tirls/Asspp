//
//  AuthenticationService.swift
//  Asspp
//
//  Created by 秋星桥 on 2024/7/11.
//

import ApplePackage
import Foundation
import Logging

extension AppStore {
    enum AuthenticationError: Error {
        case accountNotFound
    }

    /// Signs in with ipatool's Store engine when this build includes it;
    /// otherwise with ApplePackage's SAP-signed authenticator.
    @MainActor
    func authenticate(email: String, password: String, code: String, using session: ApplePackage.Authenticator?) async throws -> UserAccount {
        logger.info("starting authentication for user")
        do {
            let userAccount: UserAccount
            if IPATool.isAvailable {
                let ipatoolAccount = try await IPATool.login(email: email, password: password, code: code)
                userAccount = try save(email: email, account: Self.appleAccount(from: ipatoolAccount), ipatool: ipatoolAccount)
            } else {
                let authenticator: ApplePackage.Authenticator
                if let session {
                    authenticator = session
                } else {
                    authenticator = try await ApplePackage.Authenticator()
                }
                let appleAccount = try await authenticator.authenticate(
                    email: email,
                    password: password,
                    code: code,
                )
                userAccount = try save(email: email, account: appleAccount)
            }
            logger.info("authentication successful for user")
            return userAccount
        } catch {
            logger.error("authentication failed for user: \(error.localizedDescription)")
            throw error
        }
    }

    @MainActor
    @discardableResult
    func rotate(id: UserAccount.ID) async throws -> UserAccount? {
        logger.info("starting account rotation for user id: \(id)")
        guard let account = accounts.first(where: { $0.id == id }) else {
            logger.error("account not found for rotation, id: \(id)")
            throw AuthenticationError.accountNotFound
        }
        do {
            let updatedAccount: UserAccount
            if IPATool.isAvailable {
                let ipatoolAccount = try await IPATool.login(
                    email: account.account.email,
                    password: account.account.password,
                    code: "",
                )
                updatedAccount = try save(email: account.account.email, account: Self.appleAccount(from: ipatoolAccount), ipatool: ipatoolAccount)
            } else {
                let newAppleAccount = try await ApplePackage.Authenticator.authenticate(
                    email: account.account.email,
                    password: account.account.password,
                    code: "",
                    cookies: account.account.cookie,
                )
                updatedAccount = try save(email: account.account.email, account: newAppleAccount)
            }
            logger.info("account rotation successful for user id: \(id)")
            return updatedAccount
        } catch {
            logger.error("account rotation failed for user id: \(id): \(error.localizedDescription)")
            throw error
        }
    }

    /// ApplePackage's account model still drives the UI, search and storefront
    /// region. ipatool reports the storefront as "143465-19,29".
    nonisolated static func appleAccount(from account: IPAToolAccount) -> ApplePackage.Account {
        let store = (account.storeFront ?? "")
            .split(separator: "-", maxSplits: 1)
            .first
            .map(String.init) ?? ""
        let names = (account.name ?? "").split(separator: " ", maxSplits: 1).map(String.init)
        return ApplePackage.Account(
            email: account.email,
            password: account.password ?? "",
            appleId: account.email,
            store: store,
            firstName: names.first ?? "",
            lastName: names.count > 1 ? names[1] : "",
            passwordToken: account.passwordToken ?? "",
            directoryServicesIdentifier: account.directoryServicesIdentifier ?? "",
            cookie: [],
            pod: account.pod,
        )
    }
}

extension AppStore.UserAccount {
    /// The ipatool session for Store requests, or an error asking the user to
    /// sign in again when the account predates the ipatool engine.
    func requireIPAToolAccount() throws -> IPAToolAccount {
        guard let ipatool else { throw IPAToolError.passwordTokenExpired }
        return ipatool
    }
}
