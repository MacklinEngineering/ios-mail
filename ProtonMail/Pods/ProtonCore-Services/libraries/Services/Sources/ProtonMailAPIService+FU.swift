//
//  ProtonMailAPIService+FU.swift
//  ProtonCore-Services - Created on 5/22/20.
//
//  Copyright (c) 2022 Proton Technologies AG
//
//  This file is part of Proton Technologies AG and ProtonCore.
//
//  ProtonCore is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  ProtonCore is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with ProtonCore.  If not, see <https://www.gnu.org/licenses/>.

import Foundation
import ProtonCoreDoh
import ProtonCoreLog
import ProtonCoreNetworking
import ProtonCoreUtilities

// MARK: - Handling force upgrade

extension PMAPIService {

    func forceUpgradeHandler(errorMessage: String?) {
        if let delegate = forceUpgradeDelegate, isForceUpgradeUIPresented.transform({ $0 == false }) {
            isForceUpgradeUIPresented.mutate({ $0 = true })
            DispatchQueue.main.async {
                delegate.onForceUpgrade(message: errorMessage ?? "")
            }
        }
    }
}
