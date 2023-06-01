import Combine
@_spi(Internals) import ComposableArchitecture
import XCTest

final class EffectCancellationTests: BaseTCATestCase {
  struct CancelID: Hashable {}
  var cancellables: Set<AnyCancellable> = []

  override func tearDown() {
    super.tearDown()
    self.cancellables.removeAll()
  }

  func testCancellation() async {
    let values = LockIsolated<[Int]>([])

    let subject = PassthroughSubject<Int, Never>()
    let effect = Effect.publisher { subject }
      .cancellable(id: CancelID())

    let task = Task {
      for await n in effect.actions {
        values.withValue { $0.append(n) }
      }
    }

    await Task.megaYield()
    XCTAssertEqual(values.value, [])
    subject.send(1)
    await Task.megaYield()
    XCTAssertEqual(values.value, [1])
    subject.send(2)
    await Task.megaYield()
    XCTAssertEqual(values.value, [1, 2])

    Task.cancel(id: CancelID())

    subject.send(3)
    await Task.megaYield()
    XCTAssertEqual(values.value, [1, 2])

    await task.value
  }

  func testCancelInFlight() async {
    let values = LockIsolated<[Int]>([])

    let subject = PassthroughSubject<Int, Never>()
    let effect1 = Effect.publisher { subject }
      .cancellable(id: CancelID(), cancelInFlight: true)

    let task1 = Task {
      for await n in effect1.actions {
        values.withValue { $0.append(n) }
      }
    }
    await Task.megaYield()

    XCTAssertEqual(values.value, [])
    subject.send(1)
    await Task.megaYield()
    XCTAssertEqual(values.value, [1])
    subject.send(2)
    await Task.megaYield()
    XCTAssertEqual(values.value, [1, 2])

    defer { Task.cancel(id: CancelID()) }

    let effect2 = Effect.publisher { subject }
      .cancellable(id: CancelID(), cancelInFlight: true)

    let task2 = Task {
      for await n in effect2.actions {
        values.withValue { $0.append(n) }
      }
    }
    await Task.megaYield()

    subject.send(3)
    await Task.megaYield()
    XCTAssertEqual(values.value, [1, 2, 3])
    subject.send(4)
    await Task.megaYield()
    XCTAssertEqual(values.value, [1, 2, 3, 4])

    Task.cancel(id: CancelID())
    await task1.value
    await task2.value
  }

  func testCancellationAfterDelay() {
    var value: Int?

    Just(1)
      .delay(for: 0.15, scheduler: DispatchQueue.main)
      .eraseToEffect()
      .cancellable(id: CancelID())
      .sink { value = $0 }
      .store(in: &self.cancellables)

    XCTAssertEqual(value, nil)

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      Effect<Never>.cancel(id: CancelID())
        .sink { _ in }
        .store(in: &self.cancellables)
    }

    _ = XCTWaiter.wait(for: [self.expectation(description: "")], timeout: 1)
    XCTAssertEqual(value, nil)
  }

  func testCancellationAfterDelay_WithTestScheduler() {
    let mainQueue = DispatchQueue.test
    var value: Int?

    Effect.publisher {
      Just(1)
        .delay(for: 2, scheduler: mainQueue)
    }
    .cancellable(id: CancelID())
    .sink { value = $0 }
    .store(in: &self.cancellables)

    XCTAssertEqual(value, nil)

    mainQueue.advance(by: 1)
    Effect<Never>.cancel(id: CancelID())
      .sink { _ in }
      .store(in: &self.cancellables)

    mainQueue.run()

    XCTAssertEqual(value, nil)
  }

  func testDoubleCancellation() {
    var values: [Int] = []

    let subject = PassthroughSubject<Int, Never>()
    let effect = Effect.publisher { subject }
      .cancellable(id: CancelID())
      .cancellable(id: CancelID())

    effect
      .sink { values.append($0) }
      .store(in: &self.cancellables)

    XCTAssertEqual(values, [])
    subject.send(1)
    XCTAssertEqual(values, [1])

    Effect<Never>.cancel(id: CancelID())
      .sink { _ in }
      .store(in: &self.cancellables)

    subject.send(2)
    XCTAssertEqual(values, [1])
  }

  func testCompleteBeforeCancellation() {
    var values: [Int] = []

    let subject = PassthroughSubject<Int, Never>()
    let effect = Effect.publisher { subject }
      .cancellable(id: CancelID())

    effect
      .sink { values.append($0) }
      .store(in: &self.cancellables)

    subject.send(1)
    XCTAssertEqual(values, [1])

    subject.send(completion: .finished)
    XCTAssertEqual(values, [1])

    Effect<Never>.cancel(id: CancelID())
      .sink { _ in }
      .store(in: &self.cancellables)

    XCTAssertEqual(values, [1])
  }

  func testSharedId() {
    let mainQueue = DispatchQueue.test

    let effect1 = Just(1)
      .delay(for: 1, scheduler: mainQueue)
      .eraseToEffect()
      .cancellable(id: "id")

    let effect2 = Just(2)
      .delay(for: 2, scheduler: mainQueue)
      .eraseToEffect()
      .cancellable(id: "id")

    var expectedOutput: [Int] = []
    effect1
      .sink { expectedOutput.append($0) }
      .store(in: &cancellables)
    effect2
      .sink { expectedOutput.append($0) }
      .store(in: &cancellables)

    XCTAssertEqual(expectedOutput, [])
    mainQueue.advance(by: 1)
    XCTAssertEqual(expectedOutput, [1])
    mainQueue.advance(by: 1)
    XCTAssertEqual(expectedOutput, [1, 2])
  }

  func testImmediateCancellation() {
    let mainQueue = DispatchQueue.test

    var expectedOutput: [Int] = []
    // Don't hold onto cancellable so that it is deallocated immediately.
    _ = Effect.publisher {
      Deferred { Just(1) }
        .delay(for: 1, scheduler: mainQueue)
    }
    .cancellable(id: "id")
    .sink { expectedOutput.append($0) }

    XCTAssertEqual(expectedOutput, [])
    mainQueue.advance(by: 1)
    XCTAssertEqual(expectedOutput, [])
  }

  func testNestedMergeCancellation() {
    let effect = EffectPublisher<Int, Never>.merge(
      .publisher { (1...2).publisher }
        .cancellable(id: 1)
    )
    .cancellable(id: 2)

    var output: [Int] = []
    effect
      .sink { output.append($0) }
      .store(in: &cancellables)

    XCTAssertEqual(output, [1, 2])
  }

  func testMultipleCancellations() async {
    let mainQueue = DispatchQueue.test
    let output = LockIsolated<[AnyHashable]>([])

    struct A: Hashable {}
    struct B: Hashable {}
    struct C: Hashable {}

    let ids: [AnyHashable] = [A(), B(), C()]
    let effects = Effect.merge(
      ids.map { id in
        .publisher {
          Just(id)
            .delay(for: 1, scheduler: mainQueue)
        }
        .cancellable(id: id)
      }
    )

    let task = Task {
      for await n in effects.actions {
        output.withValue { $0.append(n) }
      }
    }
    await Task.megaYield()  // TODO: Does a yield have to be necessary here for cancellation?

    for await _ in Effect<AnyHashable>.cancel(ids: [A(), C()]).actions {}

    await mainQueue.advance(by: 1)

    await task.value
    XCTAssertEqual(output.value, [B()])
  }
}

#if DEBUG
  @testable import ComposableArchitecture

  final class Internal_EffectCancellationTests: BaseTCATestCase {
    var cancellables: Set<AnyCancellable> = []

    func testCancellablesCleanUp_OnComplete() async {
      let id = UUID()

      for await _ in Effect.send(1).cancellable(id: id).actions {}

      XCTAssertEqual(_cancellationCancellables.exists(at: id, path: NavigationIDPath()), false)
    }

    func testCancellablesCleanUp_OnCancel() async {
      let id = UUID()

      let mainQueue = DispatchQueue.test
      let effect = Effect.publisher {
        Just(1)
          .delay(for: 1, scheduler: mainQueue)
      }
      .cancellable(id: id)

      let task = Task {
        for await _ in effect.actions {
        }
      }
      await Task.megaYield()

      Task.cancel(id: id)

      await task.value

      XCTAssertEqual(_cancellationCancellables.exists(at: id, path: NavigationIDPath()), false)
    }

    @available(*, deprecated)
    func testConcurrentCancels() {
      let queues = [
        DispatchQueue.main,
        DispatchQueue.global(qos: .background),
        DispatchQueue.global(qos: .default),
        DispatchQueue.global(qos: .unspecified),
        DispatchQueue.global(qos: .userInitiated),
        DispatchQueue.global(qos: .userInteractive),
        DispatchQueue.global(qos: .utility),
      ]
      let ids = (1...10).map { _ in UUID() }

      let effect = EffectPublisher.merge(
        (1...1_000).map { idx -> EffectPublisher<Int, Never> in
          let id = ids[idx % 10]

          return EffectPublisher.merge(
            .publisher {
              Just(idx)
                .delay(
                  for: .milliseconds(Int.random(in: 1...100)), scheduler: queues.randomElement()!
                )
            }
            .cancellable(id: id),

            .publisher {
              Empty()
                .delay(
                  for: .milliseconds(Int.random(in: 1...100)), scheduler: queues.randomElement()!
                )
                .handleEvents(receiveCompletion: { _ in Task.cancel(id: id) })
            }
          )
        }
      )

      let expectation = self.expectation(description: "wait")
      // NB: `for await _ in effect.actions` blows the stack with 1,000 merged publishers
      effect
        .sink(receiveCompletion: { _ in expectation.fulfill() }, receiveValue: { _ in })
        .store(in: &self.cancellables)
      self.wait(for: [expectation], timeout: 999)

      for id in ids {
        XCTAssertEqual(
          _cancellationCancellables.exists(at: id, path: NavigationIDPath()),
          false,
          "cancellationCancellables should not contain id \(id)"
        )
      }
    }

    func testAsyncConcurrentCancels() async {
      XCTAssertTrue(!Thread.isMainThread)
      let ids = (1...100).map { _ in UUID() }

      let areCancelled = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
        (1...10_000).forEach { index in
          let id = ids[index.quotientAndRemainder(dividingBy: ids.count).remainder]
          group.addTask {
            await withTaskCancellation(id: id) {
              nil == (try? await Task.sleep(nanoseconds: 2_000_000_000))
            }
          }
          Task {
            try? await Task.sleep(nanoseconds: .random(in: 1_000_000...2_000_000))
            Task.cancel(id: id)
          }
        }
        return await group.reduce(into: [Bool]()) { $0.append($1) }
      }

      XCTAssertTrue(areCancelled.allSatisfy({ isCancelled in isCancelled }))

      for id in ids {
        XCTAssertEqual(
          _cancellationCancellables.exists(at: id, path: NavigationIDPath()),
          false,
          "cancellationCancellables should not contain id \(id)"
        )
      }
    }

    @available(*, deprecated)
    func testNestedCancels() {
      let id = UUID()

      var effect = Effect.publisher {
        Empty<Void, Never>(completeImmediately: false)
      }
      .cancellable(id: id)

      for _ in 1...1_000 {
        effect = effect.cancellable(id: id)
      }

      // NB: `for await _ in effect.actions` blows the stack with 1,000 chained publishers
      effect
        .sink(receiveValue: { _ in })
        .store(in: &cancellables)

      cancellables.removeAll()

      XCTAssertEqual(_cancellationCancellables.exists(at: id, path: NavigationIDPath()), false)
    }

    func testCancelIDHash() {
      struct CancelID1: Hashable {}
      struct CancelID2: Hashable {}
      let id1 = _CancelID(id: CancelID1(), navigationIDPath: NavigationIDPath())
      let id2 = _CancelID(id: CancelID2(), navigationIDPath: NavigationIDPath())
      XCTAssertNotEqual(id1, id2)
      // NB: We hash the type of the cancel ID to give more variance in the hash since all empty
      //     structs in Swift have the same hash value.
      XCTAssertNotEqual(id1.hashValue, id2.hashValue)
    }
  }
#endif
