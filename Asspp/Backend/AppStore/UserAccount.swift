//
//  UserAccount.swift
//  Asspp
//
//  Created by 秋星桥 on 2024/7/11.
//

import ApplePackage
import Foundation

extension AppStore {
    struct UserAccount: Codable, Identifiable, Hashable, Equatable, Sendable {
        var id: String {
            account.email
        }

        var account: ApplePackage.Account
        /// Session from the ipatool Store engine. Optional so accounts saved by
        /// earlier versions still decode; they sign in again before downloading.
        var ipatool: IPAToolAccount?

        init(account: ApplePackage.Account, ipatool: IPAToolAccount? = nil) {
            self.account = account
            self.ipatool = ipatool
        }

        static func == (lhs: UserAccount, rhs: UserAccount) -> Bool {
            lhs.id == rhs.id
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
    }
}
