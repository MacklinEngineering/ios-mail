//
//  MenuViewController.swift
//  Proton Mail
//
//
//  Copyright (c) 2019 Proton AG
//
//  This file is part of Proton Mail.
//
//  Proton Mail is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Proton Mail is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Proton Mail.  If not, see <https://www.gnu.org/licenses/>.

import Foundation
import ProtonCoreAccountSwitcher
import ProtonCoreNetworking
import ProtonCoreUIFoundations
import SideMenuSwift

protocol MenuCoordinatorDelegate: AnyObject {
    func lockTheScreen()
}

// sourcery: mock
protocol MenuCoordinatorProtocol: AnyObject {
    func go(to labelInfo: MenuLabel, deepLink: DeepLink?)
    func closeMenu()
    func lockTheScreen()
    func update(menuWidth: CGFloat)
}

final class MenuCoordinator: CoordinatorDismissalObserver, MenuCoordinatorProtocol {
    enum Setup: String {
        case switchUser = "USER"
        case switchUserFromNotification = "UserFromNotification"
        case switchInboxFolder = "SwitchInboxFolder"
        init?(rawValue: String) {
            switch rawValue {
            case "USER":
                self = .switchUser
            case "UserFromNotification":
                self = .switchUserFromNotification
            case "SwitchInboxFolder":
                self = .switchInboxFolder
            default:
                return nil
            }
        }
    }

    typealias Dependencies = MenuViewModel.Dependencies
    & SignInCoordinatorEnvironment.Dependencies
    & HasFeatureFlagCache
    & HasLastUpdatedStoreProtocol
    & HasPushNotificationService

    private(set) var viewController: MenuViewController?
    private let viewModel: MenuVMProtocol

    private var menuWidth: CGFloat
    private let dependencies: Dependencies
    var pendingActionAfterDismissal: (() -> Void)?
    private var mailboxCoordinator: MailboxCoordinator?
    let sideMenu: PMSideMenuController
    private var settingsDeviceCoordinator: SettingsDeviceCoordinator?
    private var currentLocation: MenuLabel?
    weak var delegate: MenuCoordinatorDelegate?

    init(dependencies: Dependencies, sideMenu: PMSideMenuController, menuWidth: CGFloat) {
        // Setup side menu setting
        SideMenuController.preferences.basic.menuWidth = menuWidth
        SideMenuController.preferences.basic.position = .sideBySide
        SideMenuController.preferences.basic.enablePanGesture = true
        SideMenuController.preferences.basic.enableRubberEffectWhenPanning = false
        SideMenuController.preferences.basic.shouldKeepMenuOpen = true
        SideMenuController.preferences.animation.shouldAddShadowWhenRevealing = true
        SideMenuController.preferences.animation.shadowColor = .black
        SideMenuController.preferences.animation.shadowAlpha = 0.52
        SideMenuController.preferences.animation.revealDuration = 0.25
        SideMenuController.preferences.animation.hideDuration = 0.25
        self.menuWidth = menuWidth
        self.sideMenu = sideMenu

        self.dependencies = dependencies
        let viewModel = MenuViewModel(dependencies: dependencies)
        self.viewModel = viewModel
        viewModel.coordinator = self
    }

    func start(launchedByNotification: Bool = false) {
        let menuView = MenuViewController(viewModel: self.viewModel)
        if let viewModel = self.viewModel as? MenuViewModel {
            viewModel.set(delegate: menuView)
        }
        self.viewController = menuView
        self.viewModel.set(menuWidth: self.menuWidth)
        sideMenu.menuViewController = menuView

        if launchedByNotification {
            presentInitialPage()
        }
    }

    func update(menuWidth: CGFloat) {
        SideMenuController.preferences.basic.menuWidth = menuWidth
        self.menuWidth = menuWidth
    }

    func follow(_ deepLink: DeepLink) {
        if dependencies.pushService.hasCachedNotificationOptions() {
            SystemLogger.log(
                message: "Menu handle cached notification options",
                category: .notificationDebug
            )
            dependencies.pushService.processCachedLaunchOptions()
            return
        }
        var start = deepLink.popFirst
        start = self.processUserInfoIn(node: start)
        start = switchFolderIfNeeded(node: start)

        guard let path = start ?? deepLink.popFirst,
              let label = MenuCoordinator.getLocation(by: path.name, value: path.value)
        else {
            return
        }

        SystemLogger.log(
            message: "Menu follow: go to \(label.location.labelID),  \(deepLink.debugDescription)",
            category: .notificationDebug
        )
        self.go(to: label, deepLink: deepLink)
    }

    // swiftlint:disable:next function_body_length
    func go(to labelInfo: MenuLabel, deepLink: DeepLink? = nil) {
        // in some cases we should highlight a different row in the side menu, or none at all
        var labelToHighlight: MenuLabel? = labelInfo

        switch labelInfo.location {
        case .customize:
            self.handleCustomLabel(labelInfo: labelInfo, deepLink: deepLink)
        case .inbox, .draft, .sent, .starred, .archive, .spam, .trash, .allmail, .scheduled, .almostAllMail:
            if currentLocation?.location == labelInfo.location,
               let deepLink = deepLink,
               mailboxCoordinator?.viewModel.user.userID == viewModel.currentUser?.userID {
                SystemLogger.log(
                    message: "Menu go: mailbox coordinator start to follow.\n\(deepLink.debugDescription)",
                    category: .notificationDebug
                )
                mailboxCoordinator?.follow(deepLink)
            } else {
                self.navigateToMailBox(labelInfo: labelInfo, deepLink: deepLink)
            }
        case .subscription:
            self.navigateToSubscribe()
        case .settings:
            self.navigateToSettings(deepLink: deepLink)
            labelToHighlight = nil
        case .contacts:
            self.navigateToContact()
        case .bugs:
            self.navigateToBugReport()
        case .accountManger:
            self.navigateToAccountManager()
        case .addAccount:
            let mail = labelInfo.name
            self.navigateToAddAccount(mail: mail)
        case .addLabel:
            self.navigateToCreateFolder(type: .label)
        case .addFolder:
            self.navigateToCreateFolder(type: .folder)
        case .sendFeedback:
            let inboxLabel = MenuLabel(location: .inbox)
            labelToHighlight = inboxLabel
            if checkIsCurrentViewInInboxView() {
                sideMenu.hideMenu()
                let inbox = (sideMenu.contentViewController as? UINavigationController)?
                    .topViewController as? MailboxViewController
                inbox?.showFeedbackViewIfNeeded(forceToShow: true)
            } else {
                self.navigateToMailBox(labelInfo: inboxLabel, deepLink: deepLink, showFeedbackActionSheet: true)
            }
        case .referAFriend:
            navigateToReferralView()
            labelToHighlight = nil
        default:
            break
        }
        currentLocation = labelInfo
        if let labelToHighlight = labelToHighlight {
            self.viewModel.highlight(label: labelToHighlight)
        }
    }

    func lockTheScreen() {
        delegate?.lockTheScreen()
    }

    func closeMenu() {
        sideMenu.hideMenu()
    }

    private func checkIsCurrentViewInInboxView() -> Bool {
        return ((sideMenu.contentViewController as? UINavigationController)?
                    .topViewController as? MailboxViewController)?.viewModel.labelID == Message.Location.inbox.labelID
    }
}

// MARK: helper function

extension MenuCoordinator {
    /// If the node contain user info return `nil` after processed
    private func processUserInfoIn(node: DeepLink.Node?) -> DeepLink.Node? {
        guard let setup = node,
              let dest = Setup(rawValue: setup.name),
              let sessionID = setup.value
        else {
            return node
        }

        guard let user = dependencies.usersManager.getUser(by: sessionID) else {
            return node
        }

        guard dependencies.usersManager.firstUser?.userID != user.userID else {
            return nil
        }

        switch dest {
        case .switchUser:
            viewModel.activateUser(id: user.userID)
        case .switchUserFromNotification:
            let isAnotherUser = dependencies.usersManager.firstUser?.userInfo.userId ?? "" != user.userInfo.userId
            viewModel.activateUser(id: user.userID)
            // viewController?.setupLabelsIfViewIsLoaded()
            // rebase todo, check MR 496
            if isAnotherUser {
                String(format: LocalString._switch_account_by_click_notification,
                       user.defaultEmail).alertToastBottom()
            }
        default:
            break
        }
        return nil
    }

    private func switchFolderIfNeeded(node: DeepLink.Node?) -> DeepLink.Node? {
        guard let node = node,
              let dest = Setup(rawValue: node.name),
              dest == .switchInboxFolder,
              let folderID = node.value else {
            return node
        }
        switchFolderIfNeeded(labelID: .init(folderID))
        return nil
    }

    private func switchFolderIfNeeded(labelID: LabelID) {
        guard currentLocation?.location.rawLabelID != labelID.rawValue else {
            return
        }
        let location = LabelLocation(id: labelID.rawValue, name: nil)
        let menuLabel = MenuLabel(location: location)
        navigateToMailBox(labelInfo: menuLabel, deepLink: nil, isSwitchEvent: true)
        currentLocation = menuLabel
        viewModel.highlight(label: menuLabel)
    }

    private class func getLocation(by path: String, value: String?) -> MenuLabel? {
        switch path {
        case "toMailboxSegue",
             "toLabelboxSegue",
             String(describing: MailboxViewController.self):
            let value = value ?? "0"
            let location = LabelLocation(id: value, name: nil)
            return MenuLabel(location: location)
        case String(describing: SettingsDeviceViewController.self):
            return MenuLabel(location: .settings)
        case "toBugsSegue":
            return MenuLabel(location: .bugs)
        case "toContactsSegue":
            return MenuLabel(location: .contacts)
        case "Subscription":
            return MenuLabel(location: .subscription)
        case "toBugPop":
            return MenuLabel(location: .bugs)
        case "toAccountManager":
            return MenuLabel(location: .accountManger)
        case .skeletonTemplate:
            return MenuLabel(location: .customize(.skeletonTemplate, value))
        default:
            return nil
        }
    }

    private func setupContentVC(destination: UIViewController) {
        if sideMenu.isViewLoaded {
            sideMenu.setContentViewController(to: destination)
            sideMenu.hideMenu(animated: true, completion: nil)
        } else {
            // App is just launched
            sideMenu.contentViewController = destination
        }
    }

    private func queryLabel(id: LabelID) -> LabelEntity? {
        guard let user = dependencies.usersManager.firstUser else {
            return nil
        }
        let labelService = user.labelService
        return labelService.label(by: id)
    }
}

// MARK: Navigation

extension MenuCoordinator {
    func handleSwitchView(deepLink: DeepLink?) {
        guard let deepLink = deepLink else {
            // There is no previous states , navigate to inbox
            self.presentInitialPage()
            return
        }
        follow(deepLink)
    }

    private func presentInitialPage() {
        if currentLocation?.location == .inbox { return }
        let label = MenuLabel(location: .inbox)
        go(to: label)
    }

    private func handleCustomLabel(labelInfo: MenuLabel, deepLink: DeepLink?) {
        if case .customize(let id, _) = labelInfo.location {
            if id == .skeletonTemplate {
                self.navigateToSkeletonVC(labelInfo: labelInfo)
            } else {
                self.navigateToMailBox(labelInfo: labelInfo, deepLink: deepLink)
            }
        }
    }

    private func createMailboxViewModel(
        userManager: UserManager,
        labelID: LabelID,
        labelInfo: LabelInfo?
    ) -> MailboxViewModel {
        return MailboxViewModel(
            labelID: labelID,
            label: labelInfo,
            userManager: userManager,
            pushService: dependencies.pushService,
            coreDataContextProvider: dependencies.contextProvider,
            lastUpdatedStore: dependencies.lastUpdatedStore,
            conversationStateProvider: userManager.conversationStateService,
            contactGroupProvider: userManager.contactGroupService,
            labelProvider: userManager.labelService,
            contactProvider: userManager.contactService,
            conversationProvider: userManager.conversationService,
            eventsService: userManager.eventsService,
            dependencies: userManager.container,
            toolbarActionProvider: userManager,
            saveToolbarActionUseCase: SaveToolbarActionSettings(
                dependencies: .init(user: userManager)
            ),
            totalUserCountClosure: { [weak self] in
                return self?.dependencies.usersManager.count ?? 0
            }
        )
    }

    private func navigateToMailBox(
        labelInfo: MenuLabel,
        deepLink: DeepLink?,
        showFeedbackActionSheet: Bool = false,
        isSwitchEvent: Bool = false
    ) {
        guard !self.scrollToLatestMessageInConversationViewIfPossible(deepLink) else {
            return
        }

        guard let user = dependencies.usersManager.firstUser else {
            return
        }

        let viewModel: MailboxViewModel
        switch labelInfo.location {
        case .customize(let id, _):
            guard let label = queryLabel(id: LabelID(id)), labelInfo.type == .folder || labelInfo.type == .label else {
                return
            }
            viewModel = createMailboxViewModel(
                userManager: user,
                labelID: label.labelID,
                labelInfo: LabelInfo(name: label.name)
            )

        case .inbox, .draft, .sent, .starred, .archive, .spam, .trash, .allmail, .scheduled, .almostAllMail:
            viewModel = createMailboxViewModel(
                userManager: user,
                labelID: labelInfo.location.labelID,
                labelInfo: nil
            )
        default:
            return
        }

        let userContainer = user.container

        let view = MailboxViewController(viewModel: viewModel, dependencies: userContainer)
        view.scheduleUserFeedbackCallOnAppear = showFeedbackActionSheet
        let navigation: UINavigationController
        if isSwitchEvent,
           let navigationController = self.mailboxCoordinator?.navigation {
            var viewControllers = navigationController.viewControllers
            viewControllers[0] = view
            navigationController.setViewControllers(viewControllers, animated: false)
            navigation = navigationController
        } else {
            navigation = UINavigationController(rootViewController: view)
        }

        let mailbox = MailboxCoordinator(
            sideMenu: self.viewController?.sideMenuController,
            nav: navigation,
            viewController: view,
            viewModel: viewModel,
            dependencies: userContainer
        )
        mailbox.start()
        if let deeplink = deepLink {
            mailbox.follow(deeplink)
        }
        self.setupContentVC(destination: navigation)
        self.mailboxCoordinator = mailbox
    }

    private func navigateToSubscribe() {
        guard let user = dependencies.usersManager.firstUser,
              let sideMenuViewController = viewController?.sideMenuController else { return }
        let paymentsUI = user.container.paymentsUIFactory.makeView()
        let coordinator = StorefrontCoordinator(
            paymentsUI: paymentsUI,
            sideMenu: sideMenuViewController,
            eventsService: user.eventsService
        )
        coordinator.start()
    }

    private func navigateToSettings(deepLink: DeepLink?) {
        let navigation = UINavigationController()
        navigation.modalPresentationStyle = .fullScreen

        guard let userManager = dependencies.usersManager.firstUser else {
            return
        }

        let settings = SettingsDeviceCoordinator(
            navigationController: navigation,
            dependencies: userManager.container
        )
        settings.start()
        self.settingsDeviceCoordinator = settings

        guard let sideMenu = self.viewController?.sideMenuController else {
            return
        }

        sideMenu.present(navigation, animated: true) {
            sideMenu.hideMenu()
        }
        if deepLink != nil {
            // Make sure the viewDidLoad() is called when the app is navigated with deeplink.
            navigation.viewControllers.first?.loadViewIfNeeded()
        }
        settings.follow(deepLink: deepLink)
    }

    private func navigateToContact() {
        let view = ContactTabBarViewController()
        guard let user = dependencies.usersManager.firstUser else {
            return
        }
        let contacts = ContactTabBarCoordinator(sideMenu: viewController?.sideMenuController,
                                                vc: view,
                                                dependencies: user.container)
        contacts.start()
        self.setupContentVC(destination: view)
    }

    private func navigateToBugReport() {
        guard let user = dependencies.usersManager.firstUser else {
            return
        }

        let view = ReportBugsViewController(dependencies: user.container)
        self.viewModel.highlight(label: MenuLabel(location: .bugs))
        let navigation = UINavigationController(rootViewController: view)
        self.setupContentVC(destination: navigation)
    }

    private func navigateToAccountManager() {
        guard let menuVC = self.viewController else {
            return
        }

        let view = AccountManagerVC.instance()
        let list = self.viewModel.getAccountList()
        let viewModel = AccountManagerViewModel(accounts: list, uiDelegate: view)
        viewModel.set(delegate: menuVC)
        guard let nav = view.navigationController else {
            return
        }

        sideMenu.present(nav, animated: true) { [weak self] in
            self?.sideMenu.hideMenu()
        }
    }

    private func navigateToAddAccount(mail: String) {
        let signInEnvironment = SignInCoordinatorEnvironment.live(
            dependencies: dependencies
        )

        let coordinator: SignInCoordinator = .loginFlowForSecondAndAnotherAccount(
            username: mail.isEmpty ? nil : mail,
            environment: signInEnvironment
        ) { [weak self] result in
            switch result {
            case .succeeded:
                self?.sideMenu.dismiss(animated: false, completion: nil)
            case .loggedInFreeAccountsLimitReached:
                self?.sideMenu.dismiss(animated: false, completion: nil)
            case .alreadyLoggedIn:
                self?.sideMenu.dismiss(animated: false, completion: nil)
            case .userWantsToGoToTroubleshooting:
                self?.sideMenu.dismiss(animated: false) { [weak self] in self?.navigateToTroubleshooting() }
            case .errored:
                self?.sideMenu.dismiss(animated: false) { [weak self] in self?.navigateToAccountManager() }
            case .dismissed:
                self?.sideMenu.dismiss(animated: false) { [weak self] in self?.navigateToAccountManager() }
            }
        }
        coordinator.delegate = self

        let view = coordinator.actualViewController
        view.modalPresentationStyle = .overCurrentContext
        sideMenu.present(view, animated: false) { [weak self] in
            self?.sideMenu.hideMenu()
            self?.dependencies.usersManager.firstUser?.deactivatePayments()
            coordinator.start()
        }
    }

    private func navigateToTroubleshooting() {
        sideMenu.present(
            doh: BackendConfiguration.shared.doh,
            modalPresentationStyle: .fullScreen,
            onPresent: { [weak self] in
                self?.sideMenu.hideMenu()
            },
            onDismiss: { [weak self] in
                self?.navigateToAccountManager()
            }
        )
    }

    private func navigateToCreateFolder(type: PMLabelType) {
        guard let user = self.viewModel.currentUser else { return }
        var folders = self.viewModel.folderItems
        if folders.count == 1,
           let first = folders.first,
           first.location == .addFolder {
            folders = []
        }
        let dependencies = LabelEditViewModel.Dependencies(userManager: user)
        let labelEditNavigationController = LabelEditStackBuilder.make(
            editMode: .creation,
            type: type,
            labels: folders,
            dependencies: dependencies,
            coordinatorDismissalObserver: self
        )
        sideMenu.present(labelEditNavigationController, animated: true) { [weak self] in
            self?.sideMenu.hideMenu()
        }
    }

    private func scrollToLatestMessageInConversationViewIfPossible(_ deepLink: DeepLink?) -> Bool {
        guard dependencies.usersManager.firstUser?.conversationStateService.viewMode == .conversation,
              let deepLink = deepLink
        else {
            return false
        }
        // find messageId in deepLink
        var path = deepLink.first
        var messageId: String?
        while path != nil {
            if path?.name == "SingleMessageViewController" {
                messageId = path?.value
                break
            } else {
                path = path?.next
            }
        }

        guard let messageId = messageId,
              let message = dependencies.contextProvider.read(block: { context in
                  if let msg = Message.messageForMessageID(messageId, in: context) {
                      return MessageEntity(msg)
                  } else {
                      return nil
                  }
              }) else { return false }

        var isFound = false
        if let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) {
            window.enumerateViewControllerHierarchy { controller, stop in
                if let conversationVC = controller as? ConversationViewController,
                   conversationVC.viewModel.conversation.conversationID == message.conversationID {
                    conversationVC.showMessage(of: message.messageID)
                    isFound = true
                    stop = true
                }
            }
        }
        return isFound
    }

    private func navigateToSkeletonVC(labelInfo: MenuLabel) {
        guard case let .customize(_, value) = labelInfo.location else { return }
        // If this is triggered by SignInCoordinator
        // Disable skeleton timer
        let isEnabledTimeout = value != String(describing: SignInCoordinator.self)
        let skeletonVC = SkeletonViewController.instance(isEnabledTimeout: isEnabledTimeout)
        guard let navigation = skeletonVC.navigationController else { return }
        self.setupContentVC(destination: navigation)
    }

    private func navigateToReferralView() {
        guard let referralLink = dependencies.usersManager.firstUser?
            .userInfo.referralProgram?.link else {
            return
        }
        let view = ReferralShareViewController(
            referralLink: referralLink
        )
        let navigation = UINavigationController(rootViewController: view)
        navigation.modalPresentationStyle = .fullScreen
        sideMenu.present(navigation, animated: true)
    }
}

extension MenuCoordinator: SignInCoordinatorDelegate {
    func didStop() {
        guard let user = dependencies.usersManager.firstUser else {
            return
        }
        self.viewModel.activateUser(id: UserID(user.userInfo.userId))
        let label = MenuLabel(location: .inbox)
        self.navigateToMailBox(labelInfo: label, deepLink: nil)
    }
}
