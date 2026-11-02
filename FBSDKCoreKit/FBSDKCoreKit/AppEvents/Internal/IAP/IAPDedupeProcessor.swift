/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

final class IAPDedupeProcessor: _IAPDedupeProcessing {
  private(set) var isEnabled = false
  private var manuallyLoggedEvents: [DedupableEvent] = []
  private var implicitlyLoggedEvents: [DedupableEvent] = []
  private var timer: Timer?

  private static let dateFormatter = DateFormatter()
  private static var valueToSumKey = "_valueToSum"
  static var configuredDependencies: TypeDependencies?
  static var defaultDependencies: TypeDependencies? = .init(
    eventLogger: AppEvents.shared,
    appEventsConfigurationProvider: _AppEventsConfigurationManager.shared,
    dataStore: UserDefaults.standard
  )

  private static var dedupWindow: TimeInterval {
    guard let dependencies = try? Self.getDependencies() else {
      return IAPConstants.defaultIAPDedupeWindow
    }
    let configuredWindow =
      dependencies.appEventsConfigurationProvider.cachedAppEventsConfiguration.iapManualAndAutoLogDedupWindow
    return TimeInterval(configuredWindow / 1000)
  }

  static let shared = IAPDedupeProcessor()

  private init() {
    Self.dateFormatter.timeZone = TimeZone(abbreviation: "UTC")
    Self.dateFormatter.dateFormat = IAPConstants.transactionDateFormat
  }
}

// MARK: - DependentAsObject

extension IAPDedupeProcessor: DependentAsType {
  struct TypeDependencies {
    var eventLogger: EventLogging
    var appEventsConfigurationProvider: _AppEventsConfigurationProviding
    var dataStore: DataPersisting
  }
}

// MARK: - Public APIs

extension IAPDedupeProcessor {
  func enable() {
    guard !isEnabled else {
      return
    }
    synchronized(self) {
      isEnabled = true
    }
  }

  func disable() {
    guard isEnabled else {
      return
    }
    synchronized(self) {
      isEnabled = false
    }
  }

  func saveNonProcessedEvents() {
    guard let dependencies = try? Self.getDependencies() else {
      return
    }
    var manualEvents: [DedupableEvent] = []
    var implicitEvents: [DedupableEvent] = []
    synchronized(self) {
      cancelDedupTimer()
      manualEvents = manuallyLoggedEvents
      manuallyLoggedEvents = []
      implicitEvents = implicitlyLoggedEvents
      implicitlyLoggedEvents = []
    }
    if !manualEvents.isEmpty, let manualData = try? JSONEncoder().encode(manualEvents) {
      dependencies.dataStore.fb_setObject(manualData, forKey: IAPConstants.manuallyLoggedDedupableEventsKey)
    }
    if !implicitEvents.isEmpty, let implicitData = try? JSONEncoder().encode(implicitEvents) {
      dependencies.dataStore.fb_setObject(implicitData, forKey: IAPConstants.implicitlyLoggedDedupableEventsKey)
    }
  }

  func processSavedEvents() {
    guard let dependencies = try? Self.getDependencies() else {
      return
    }
    var manualEvents: [DedupableEvent] = []
    if let data = dependencies.dataStore.fb_data(forKey: IAPConstants.manuallyLoggedDedupableEventsKey),
       let decodedEvents = try? JSONDecoder().decode([DedupableEvent].self, from: data),
       !decodedEvents.isEmpty {
      dependencies.dataStore.fb_removeObject(forKey: IAPConstants.manuallyLoggedDedupableEventsKey)
      manualEvents = decodedEvents
    }
    var implicitEvents: [DedupableEvent] = []
    if let data = dependencies.dataStore.fb_data(forKey: IAPConstants.implicitlyLoggedDedupableEventsKey),
       let decodedEvents = try? JSONDecoder().decode([DedupableEvent].self, from: data),
       !decodedEvents.isEmpty {
      dependencies.dataStore.fb_removeObject(forKey: IAPConstants.implicitlyLoggedDedupableEventsKey)
      implicitEvents = decodedEvents
    }
    if implicitEvents.isEmpty, manualEvents.isEmpty {
      return
    }
    synchronized(self) {
      for event in manualEvents {
        manuallyLoggedEvents.append(event)
      }
      for event in implicitEvents {
        implicitlyLoggedEvents.append(event)
      }
      scheduleDedupTimer()
    }
  }

  func shouldDedupeEvent(
    _ eventName: AppEvents.Name,
    valueToSum: NSNumber?,
    parameters: [AppEvents.ParameterName: Any]?
  ) -> Bool {
    guard IAPConstants.dedupableEvents.contains(eventName) else {
      return false
    }
    guard let dependencies = try? Self.getDependencies() else {
      return false
    }
    guard let parameters = parameters?.stringKeys.keys else {
      return false
    }
    let productionDedupConfig =
      dependencies.appEventsConfigurationProvider.cachedAppEventsConfiguration.iapProdDedupConfiguration
    let testDedupConfig =
      dependencies.appEventsConfigurationProvider.cachedAppEventsConfiguration.iapTestDedupConfiguration
    let valueParameters = Set(productionDedupConfig[Self.valueToSumKey] ?? [Self.valueToSumKey])
    let currencyKey = AppEvents.ParameterName.currency.rawValue
    let currencyParameters = Set(productionDedupConfig[currencyKey] ?? [currencyKey])
    let iapParameters = Set(
      productionDedupConfig.filter { $0.key != Self.valueToSumKey && $0.key != currencyKey }.values.flatMap { $0 } +
        testDedupConfig.values.flatMap { $0 }
    )
    let valueCheck = valueToSum != nil || !valueParameters.isDisjoint(with: parameters)
    return valueCheck && !currencyParameters.isDisjoint(with: parameters) && !iapParameters.isDisjoint(with: parameters)
  }

  func processManualEvent(
    _ eventName: AppEvents.Name,
    valueToSum: NSNumber?,
    parameters: [AppEvents.ParameterName: Any]?,
    accessToken: AccessToken?,
    operationalParameters: [AppOperationalDataType: [String: Any]]?
  ) {
    var manualParams = parameters
    if manualParams == nil {
      manualParams = [
        AppEvents.ParameterName.logTime: Int(_AppEventsUtility.shared.unixTimeNow),
      ]
    } else {
      if let keys = manualParams?.keys, !keys.contains(AppEvents.ParameterName.logTime) {
        manualParams?[AppEvents.ParameterName.logTime] = Int(_AppEventsUtility.shared.unixTimeNow)
      }
    }
    Task {
      await IAPTransactionObserver.shared.observeNewTransactions()
    }
    let event = DedupableEvent(
      eventName: eventName,
      valueToSum: valueToSum,
      parameters: manualParams?.stringKeys,
      isImplicitEvent: false,
      accessToken: accessToken,
      operationalParameters: operationalParameters?.stringKeys
    )
    synchronized(self) {
      manuallyLoggedEvents.append(event)
      scheduleDedupTimer()
    }
  }

  func processImplicitEvent(
    _ eventName: AppEvents.Name,
    valueToSum: NSNumber?,
    parameters: [AppEvents.ParameterName: Any]?,
    accessToken: AccessToken?,
    operationalParameters: [AppOperationalDataType: [String: Any]]?
  ) {
    let event = DedupableEvent(
      eventName: eventName,
      valueToSum: valueToSum,
      parameters: parameters?.stringKeys,
      isImplicitEvent: true,
      accessToken: accessToken,
      operationalParameters: operationalParameters?.stringKeys
    )
    synchronized(self) {
      implicitlyLoggedEvents.append(event)
      scheduleDedupTimer()
    }
  }

  class func performDedup(implicitEvents: inout [DedupableEvent], manualEvents: inout [DedupableEvent]) {
    guard let dependencies = try? Self.getDependencies() else {
      return
    }
    let productionDedupConfig =
      dependencies.appEventsConfigurationProvider.cachedAppEventsConfiguration.iapProdDedupConfiguration
    let testDedupConfig =
      dependencies.appEventsConfigurationProvider.cachedAppEventsConfiguration.iapTestDedupConfiguration
    for (implicitIndex, var implicitEvent) in implicitEvents.enumerated() {
      for (manualIndex, var manualEvent) in manualEvents.enumerated() {
        if !implicitEvent.hasBeenProdDeduped,
           !manualEvent.hasBeenProdDeduped,
           let dedupKey = areDuplicates(
             implicitEvent: implicitEvent,
             manualEvent: manualEvent,
             dedupConfiguration: productionDedupConfig
           ) {
          manualEvent = injectDedupeParameters(
            nonDedupedEvent: implicitEvent,
            dedupedEvent: manualEvent,
            prodDedupeKey: dedupKey,
            shouldOverrideNonDedupedEventTime: true
          )
          manualEvent.hasBeenProdDeduped = true
          implicitEvent.hasBeenProdDeduped = true
        }
        if !implicitEvent.hasBeenTestDeduped,
           !manualEvent.hasBeenTestDeduped,
           let dedupKey = areDuplicates(
             implicitEvent: implicitEvent,
             manualEvent: manualEvent,
             dedupConfiguration: testDedupConfig
           ) {
          manualEvent = injectDedupeParameters(
            nonDedupedEvent: implicitEvent,
            dedupedEvent: manualEvent,
            testDedupKey: dedupKey
          )
          manualEvent.hasBeenTestDeduped = true
          implicitEvent.hasBeenTestDeduped = true
        }
        manualEvents[manualIndex] = manualEvent
      }
      implicitEvents[implicitIndex] = implicitEvent
    }
    for implicitEvent in implicitEvents {
      dependencies.eventLogger.doLogEvent(
        implicitEvent.eventName,
        valueToSum: implicitEvent.valueToSum,
        parameters: implicitEvent.parameters?.appEventParameterKeys,
        isImplicitlyLogged: implicitEvent.isImplicitEvent,
        accessToken: implicitEvent.accessToken,
        operationalParameters: implicitEvent.operationalParameters?.appOperationalDataParameterKeys
      )
    }
    for manualEvent in manualEvents {
      dependencies.eventLogger.doLogEvent(
        manualEvent.eventName,
        valueToSum: manualEvent.valueToSum,
        parameters: manualEvent.parameters?.appEventParameterKeys,
        isImplicitlyLogged: manualEvent.isImplicitEvent,
        accessToken: manualEvent.accessToken,
        operationalParameters: manualEvent.operationalParameters?.appOperationalDataParameterKeys
      )
    }
    if dependencies.eventLogger.flushBehavior != .explicitOnly {
      dependencies.eventLogger.flush(for: .eagerlyFlushingEvent)
    }
  }

  class func areDuplicates(
    implicitEvent: DedupableEvent,
    manualEvent: DedupableEvent,
    dedupConfiguration: [String: [String]]
  ) -> String? {
    guard implicitEvent.eventName == manualEvent.eventName,
          areWithinDedupWindow(implicitEvent: implicitEvent, manualEvent: manualEvent),
          valueCheck(implicitEvent: implicitEvent, manualEvent: manualEvent, dedupConfiguration: dedupConfiguration),
          currencyCheck(implicitEvent: implicitEvent, manualEvent: manualEvent, dedupConfiguration: dedupConfiguration)
    else {
      return nil
    }
    guard let dedupKey = iapKeyCheck(
      implicitEvent: implicitEvent,
      manualEvent: manualEvent,
      dedupConfiguration: dedupConfiguration
    ) else {
      return nil
    }
    return dedupKey
  }
}

// MARK: - Private Methods

extension IAPDedupeProcessor {
  private func scheduleDedupTimer() {
    synchronized(self) {
      guard timer == nil else {
        return
      }
      let newTimer = Timer(timeInterval: Self.dedupWindow, repeats: false) { timer in
        self.dedupTimerFired(timer)
      }
      // Reserve this window before dispatching so another event cannot queue a second timer.
      timer = newTimer
      DispatchQueue.main.async {
        synchronized(self) {
          guard self.timer === newTimer else {
            return
          }
          RunLoop.main.add(newTimer, forMode: .default)
        }
      }
    }
  }

  private func cancelDedupTimer() {
    synchronized(self) {
      let cancelledTimer = timer
      timer = nil
      // A timer must be invalidated on the thread whose run loop owns it.
      DispatchQueue.main.async {
        cancelledTimer?.invalidate()
      }
    }
  }

  private func dedupTimerFired(_ firedTimer: Timer) {
    Task {
      await IAPTransactionObserver.shared.observeNewTransactions()
      guard let events = await self.takeEventsForDedupTimer(firedTimer) else {
        return
      }
      var (implicitEvents, manualEvents) = events
      Self.performDedup(implicitEvents: &implicitEvents, manualEvents: &manualEvents)
    }
  }

  @MainActor
  private func takeEventsForDedupTimer(_ firedTimer: Timer) -> ([DedupableEvent], [DedupableEvent])? {
    var implicitEvents: [DedupableEvent] = []
    var manualEvents: [DedupableEvent] = []
    var shouldProcess = false
    synchronized(self) {
      // Saving/resetting may have cancelled this window while transaction observation was suspended.
      guard timer === firedTimer else {
        return
      }
      firedTimer.invalidate()
      timer = nil
      shouldProcess = true
      implicitEvents = implicitlyLoggedEvents
      implicitlyLoggedEvents = []
      manualEvents = manuallyLoggedEvents
      manuallyLoggedEvents = []
    }
    guard shouldProcess else {
      return nil
    }
    return (implicitEvents, manualEvents)
  }

  private class func injectDedupeParameters(
    nonDedupedEvent: DedupableEvent,
    dedupedEvent: DedupableEvent,
    prodDedupeKey: String? = nil,
    testDedupKey: String? = nil,
    shouldOverrideNonDedupedEventTime: Bool = false
  ) -> DedupableEvent {
    var result = dedupedEvent
    if result.operationalParameters == nil {
      result.operationalParameters = [String: [String: Any]]()
    }
    if result.operationalParameters?[AppOperationalDataType.iapParameters.rawValue] == nil {
      result.operationalParameters?[AppOperationalDataType.iapParameters.rawValue] = [String: Any]()
    }
    if let prodDedupeKey {
      result.operationalParameters?[AppOperationalDataType.iapParameters.rawValue]?["fb_iap_actual_dedup_result"] = "1"
      // swiftlint:disable:next line_length
      result.operationalParameters?[AppOperationalDataType.iapParameters.rawValue]?["fb_iap_actual_dedup_key_used"] = prodDedupeKey
    }
    if let testDedupKey {
      result.operationalParameters?[AppOperationalDataType.iapParameters.rawValue]?["fb_iap_test_dedup_result"] = "1"
      // swiftlint:disable:next line_length
      result.operationalParameters?[AppOperationalDataType.iapParameters.rawValue]?["fb_iap_test_dedup_key_used"] = testDedupKey
    }
    if shouldOverrideNonDedupedEventTime || dedupedEvent.parameters?["fb_iap_non_deduped_event_time"] == nil {
      result.operationalParameters?[AppOperationalDataType.iapParameters.rawValue]?["fb_iap_non_deduped_event_time"] =
        Self.getUnixTimeStampFromTransactionDate(implicitEvent: nonDedupedEvent)
    }
    return result
  }

  private class func getUnixTimeStampFromTransactionDate(implicitEvent: DedupableEvent) -> TimeInterval? {
    guard let implicitTransactionDate =
      implicitEvent.parameters?[AppEvents.ParameterName.transactionDate.rawValue] as? String else {
      return nil
    }
    guard let date = dateFormatter.date(from: implicitTransactionDate) else {
      return nil
    }
    return _AppEventsUtility.shared.convert(toUnixTime: date)
  }

  private class func areWithinDedupWindow(
    implicitEvent: DedupableEvent,
    manualEvent: DedupableEvent
  ) -> Bool {
    var manualLogTime: Int?
    if let manualLogTimeInt = manualEvent.parameters?[AppEvents.ParameterName.logTime.rawValue] as? Int {
      manualLogTime = manualLogTimeInt
    } else if let manualLogTimeString = manualEvent.parameters?[AppEvents.ParameterName.logTime.rawValue] as? String {
      manualLogTime = Int(manualLogTimeString)
    } else if let manualLogTimeDouble = manualEvent.parameters?[AppEvents.ParameterName.logTime.rawValue] as? Double {
      manualLogTime = Int(manualLogTimeDouble)
    }
    guard let manualLogTime else {
      return false
    }
    let manualLogTimeInterval = TimeInterval(manualLogTime)
    guard let implicitTransactionTime = getUnixTimeStampFromTransactionDate(implicitEvent: implicitEvent) else {
      return false
    }
    let logDifference = abs(manualLogTimeInterval - implicitTransactionTime)
    return logDifference <= dedupWindow
  }

  private class func valueCheck(
    implicitEvent: DedupableEvent,
    manualEvent: DedupableEvent,
    dedupConfiguration: [String: [String]]
  ) -> Bool {
    guard let implicitValue = implicitEvent.valueToSum else {
      return false
    }
    let dedupValueKeys = dedupConfiguration[Self.valueToSumKey] ?? [Self.valueToSumKey]
    for dedupKey in dedupValueKeys {
      if dedupKey == valueToSumKey, implicitValue == manualEvent.valueToSum {
        return true
      }
      if implicitValue == manualEvent.parameters?[dedupKey] as? NSNumber {
        return true
      }
    }
    return false
  }

  private class func currencyCheck(
    implicitEvent: DedupableEvent,
    manualEvent: DedupableEvent,
    dedupConfiguration: [String: [String]]
  ) -> Bool {
    guard let implicitCurrency = implicitEvent.parameters?[AppEvents.ParameterName.currency.rawValue] as? String else {
      return false
    }
    let dedupCurrencyKeys = dedupConfiguration[AppEvents.ParameterName.currency.rawValue] ??
      [AppEvents.ParameterName.currency.rawValue]
    for dedupKey in dedupCurrencyKeys {
      if let manualCurrency = manualEvent.parameters?[dedupKey] as? String, implicitCurrency == manualCurrency {
        return true
      }
    }
    return false
  }

  private class func iapKeyCheck(
    implicitEvent: DedupableEvent,
    manualEvent: DedupableEvent,
    dedupConfiguration: [String: [String]]
  ) -> String? {
    let iapKeys = dedupConfiguration.keys
    for iapKey in iapKeys {
      if iapKey == valueToSumKey || iapKey == AppEvents.ParameterName.currency.rawValue {
        continue
      }
      let dedupKeys = dedupConfiguration[iapKey] ?? [iapKey]
      for dedupKey in dedupKeys {
        guard let manualParam = manualEvent.parameters?[dedupKey] else {
          continue
        }
        let implicitParam1 = implicitEvent.parameters?[iapKey] ?? ""
        let implicitValue1 = String(describing: implicitParam1)
        let manualValue = String(describing: manualParam)
        if !implicitValue1.isEmpty, !manualValue.isEmpty, implicitValue1 == manualValue {
          return dedupKey
        }
        // swiftlint:disable:next line_length
        let implicitParam2 = implicitEvent.operationalParameters?[AppOperationalDataType.iapParameters.rawValue]?[iapKey] ?? ""
        let implicitValue2 = String(describing: implicitParam2)
        if !implicitValue2.isEmpty, !manualValue.isEmpty, implicitValue2 == manualValue {
          return dedupKey
        }
      }
    }
    return nil
  }
}

// MARK: - DedupableEvent Struct

struct DedupableEvent: Equatable, Hashable, Codable {
  var eventName: AppEvents.Name
  var valueToSum: NSNumber?
  var parameters: [String: Any]?
  var isImplicitEvent: Bool
  var accessToken: AccessToken?
  var hasBeenProdDeduped = false
  var hasBeenTestDeduped = false
  var operationalParameters: [String: [String: Any]]?

  enum CodingKeys: CodingKey {
    case eventName
    case valueToSum
    case parameters
    case isImplicitEvent
    case accessToken
    case hasBeenProdDeduped
    case hasBeenTestDeduped
    case operationalParameters
  }

  init(
    eventName: AppEvents.Name,
    valueToSum: NSNumber?,
    parameters: [String: Any]?,
    isImplicitEvent: Bool,
    accessToken: AccessToken? = nil,
    hasBeenProdDeduped: Bool = false,
    hasBeenTestDeduped: Bool = false,
    operationalParameters: [String: [String: Any]]? = nil
  ) {
    self.eventName = eventName
    self.valueToSum = valueToSum
    self.parameters = parameters
    self.isImplicitEvent = isImplicitEvent
    self.accessToken = accessToken
    self.hasBeenProdDeduped = hasBeenProdDeduped
    self.hasBeenTestDeduped = hasBeenTestDeduped
    self.operationalParameters = operationalParameters
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let eventNameString = try container.decode(String.self, forKey: .eventName)
    eventName = AppEvents.Name(eventNameString)
    if let valueToSumData = try? container.decode(Data.self, forKey: .valueToSum) {
      valueToSum = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSNumber.self, from: valueToSumData)
    }
    if let parametersData = try? container.decode(Data.self, forKey: .parameters) {
      parameters = try JSONSerialization.jsonObject(with: parametersData, options: []) as? [String: Any]
    }
    isImplicitEvent = try container.decode(Bool.self, forKey: .isImplicitEvent)
    if let accessTokenData = try? container.decode(Data.self, forKey: .accessToken) {
      accessToken = try NSKeyedUnarchiver.unarchivedObject(ofClass: AccessToken.self, from: accessTokenData)
    }
    hasBeenProdDeduped = try container.decode(Bool.self, forKey: .hasBeenProdDeduped)
    hasBeenTestDeduped = try container.decode(Bool.self, forKey: .hasBeenTestDeduped)
    if let operationalParametersData = try? container.decode(Data.self, forKey: .operationalParameters) {
      // swiftlint:disable:next line_length
      operationalParameters = try JSONSerialization.jsonObject(with: operationalParametersData, options: []) as? [String: [String: Any]]
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(eventName.rawValue, forKey: .eventName)
    if let valueToSum {
      let valueToSumData = try NSKeyedArchiver.archivedData(withRootObject: valueToSum, requiringSecureCoding: false)
      try container.encode(valueToSumData, forKey: .valueToSum)
    }
    if let parameters {
      let parametersData = try JSONSerialization.data(withJSONObject: parameters, options: [])
      try container.encode(parametersData, forKey: .parameters)
    }
    try container.encode(isImplicitEvent, forKey: .isImplicitEvent)
    if let accessToken {
      let accessTokenData = try NSKeyedArchiver.archivedData(withRootObject: accessToken, requiringSecureCoding: false)
      try container.encode(accessTokenData, forKey: .accessToken)
    }
    try container.encode(hasBeenProdDeduped, forKey: .hasBeenProdDeduped)
    try container.encode(hasBeenTestDeduped, forKey: .hasBeenTestDeduped)
    if let operationalParameters {
      let operationalParametersData = try JSONSerialization.data(withJSONObject: operationalParameters, options: [])
      try container.encode(operationalParametersData, forKey: .operationalParameters)
    }
  }

  static func == (lhs: DedupableEvent, rhs: DedupableEvent) -> Bool {
    lhs.eventName == rhs.eventName &&
      lhs.valueToSum == rhs.valueToSum &&
      NSDictionary(dictionary: lhs.parameters ?? [:]).isEqual(to: rhs.parameters ?? [:]) &&
      lhs.isImplicitEvent == rhs.isImplicitEvent &&
      lhs.accessToken == rhs.accessToken &&
      lhs.hasBeenProdDeduped == rhs.hasBeenProdDeduped &&
      lhs.hasBeenTestDeduped == rhs.hasBeenTestDeduped
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(eventName)
    hasher.combine(valueToSum)
    hasher.combine(NSDictionary(dictionary: parameters ?? [:]))
    hasher.combine(isImplicitEvent)
    hasher.combine(accessToken)
    hasher.combine(hasBeenProdDeduped)
    hasher.combine(hasBeenTestDeduped)
  }
}

// MARK: - Extension Helpers

extension [AppEvents.ParameterName: Any] {
  var stringKeys: [String: Any] {
    self.reduce(into: [String: Any]()) { result, pair in
      result[pair.key.rawValue] = pair.value
    }
  }
}

extension [String: Any] {
  var appEventParameterKeys: [AppEvents.ParameterName: Any] {
    self.reduce(into: [AppEvents.ParameterName: Any]()) { result, pair in
      result[AppEvents.ParameterName(rawValue: pair.key)] = pair.value
    }
  }
}

extension [AppOperationalDataType: [String: Any]] {
  var stringKeys: [String: [String: Any]] {
    self.reduce(into: [String: [String: Any]]()) { result, pair in
      result[pair.key.rawValue] = pair.value
    }
  }
}

extension [String: [String: Any]] {
  var appOperationalDataParameterKeys: [AppOperationalDataType: [String: Any]] {
    self.reduce(into: [AppOperationalDataType: [String: Any]]()) { result, pair in
      result[AppOperationalDataType(rawValue: pair.key)] = pair.value
    }
  }
}

// MARK: - Testing

#if DEBUG
extension IAPDedupeProcessor {
  func reset() {
    disable()
    UserDefaults.standard.removeObject(forKey: IAPConstants.implicitlyLoggedDedupableEventsKey)
    UserDefaults.standard.removeObject(forKey: IAPConstants.manuallyLoggedDedupableEventsKey)
    Self.configuredDependencies = nil
    synchronized(self) {
      manuallyLoggedEvents = []
      implicitlyLoggedEvents = []
      cancelDedupTimer()
    }
  }

  func appendManualEvent(_ event: DedupableEvent) {
    manuallyLoggedEvents.append(event)
  }

  func appendImplicitEvent(_ event: DedupableEvent) {
    implicitlyLoggedEvents.append(event)
  }
}
#endif
