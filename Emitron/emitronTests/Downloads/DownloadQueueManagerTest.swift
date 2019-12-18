/// Copyright (c) 2019 Razeware LLC
/// 
/// Permission is hereby granted, free of charge, to any person obtaining a copy
/// of this software and associated documentation files (the "Software"), to deal
/// in the Software without restriction, including without limitation the rights
/// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
/// copies of the Software, and to permit persons to whom the Software is
/// furnished to do so, subject to the following conditions:
/// 
/// The above copyright notice and this permission notice shall be included in
/// all copies or substantial portions of the Software.
/// 
/// Notwithstanding the foregoing, you may not use, copy, modify, merge, publish,
/// distribute, sublicense, create a derivative work, and/or sell copies of the
/// Software in any work that is designed, intended, or marketed for pedagogical or
/// instructional purposes related to programming, coding, application development,
/// or information technology.  Permission for such use, copying, modification,
/// merger, publication, distribution, sublicensing, creation of derivative works,
/// or sale is expressly withheld.
/// 
/// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
/// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
/// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
/// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
/// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
/// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
/// THE SOFTWARE.

import XCTest
import GRDB
import Combine
import CombineExpectations
@testable import Emitron

class DownloadQueueManagerTest: XCTestCase {
  private var database: DatabaseWriter!
  private var persistenceStore: PersistenceStore!
  private var videoService = VideosServiceMock()
  private var downloadService: DownloadService!
  private var queueManager: DownloadQueueManager!
  private var subscriptions = Set<AnyCancellable>()

  override func setUp() {
    database = try! EmitronDatabase.testDatabase()
    persistenceStore = PersistenceStore(db: database)
    let userModelController = UserMCMock.withDownloads
    downloadService = DownloadService(persistenceStore: persistenceStore,
                                      userModelController: userModelController,
                                      videosServiceProvider: { _ in self.videoService })
    queueManager = DownloadQueueManager(persistenceStore: persistenceStore)
  }
  
  override func tearDown() {
    videoService.reset()
    subscriptions = []
  }
  
  func getAllContents() -> [Content] {
    try! database.read { db in
      try Content.fetchAll(db)
    }
  }
  
  func getAllDownloads() -> [Download] {
    try! database.read { db in
      try Download.fetchAll(db)
    }
  }
  
  func sampleDownload() -> Download {
    let screencast = ContentDetailsModelTest.Mocks.screencast
    downloadService.requestDownload(content: screencast)
    return getAllDownloads().first!
  }
  
  func samplePersistedDownload(state: Download.State = .pending) throws -> Download {
    return try database.write { db in
      let content = PersistenceMocks.content
      try content.save(db)
      
      var download = PersistenceMocks.download(for: content)
      download.state = state
      try download.save(db)
      
      return download
    }
  }
  
  func testPendingStreamSendsNewDownloads() throws {
    let recorder = queueManager.pendingStream.record()
    
    var download = sampleDownload()
    try database.write { db in
      try download.save(db)
    }
    
    let downloads = try wait(for: recorder.next(2), timeout: 1, description: "PendingDownloads")
    
    XCTAssertEqual([nil, download], downloads.map { $0?.download })
  }
  
  func testPendingStreamSendingPreExistingDownloads() throws {
    var download = sampleDownload()
    try database.write { db in
      try download.save(db)
    }
    
    let recorder = queueManager.pendingStream.record()
    let pending = try wait(for: recorder.next(), timeout: 1)
    
    XCTAssertEqual(download, pending!!.download)
  }
  
  func testDownloadQueueStreamRespectsTheMaxLimit() throws {
    let recorder = queueManager.downloadQueue.record()
    
    let download1 = try samplePersistedDownload(state: .enqueued)
    let download2 = try samplePersistedDownload(state: .enqueued)
    let _ = try samplePersistedDownload(state: .enqueued)
    
    let queue = try wait(for: recorder.next(4), timeout: 1)
    XCTAssertEqual([
      [],                     // Empty to start
      [download1],            // d1 Enqueued
      [download1, download2], // d2 Enqueued
      [download1, download2]  // Final download makes no difference
      ],
                   queue.map{ $0.map { $0.download } })
  }
  
  func testDownloadQueueStreamSendsFromThePast() throws {
    let download1 = try samplePersistedDownload(state: .enqueued)
    let download2 = try samplePersistedDownload(state: .enqueued)
    let _ = try samplePersistedDownload(state: .enqueued)
    
    let recorder = queueManager.downloadQueue.record()
    let queue = try wait(for: recorder.next(), timeout: 1)
    XCTAssertEqual([download1, download2], queue!.map { $0.download })
  }
  
  func testDownloadQueueStreamSendsInProgressFirst() throws {
    let _ = try samplePersistedDownload(state: .enqueued)
    let download2 = try samplePersistedDownload(state: .inProgress)
    let _ = try samplePersistedDownload(state: .enqueued)
    let download4 = try samplePersistedDownload(state: .inProgress)
    
    let recorder = queueManager.downloadQueue.record()
    let queue = try wait(for: recorder.next(), timeout: 1)
    XCTAssertEqual([download2, download4], queue!.map { $0.download })
  }
  
  func testDownloadQueueStreamUpdatesWhenInProgressCompleted() throws {
    let download1 = try samplePersistedDownload(state: .enqueued)
    var download2 = try samplePersistedDownload(state: .inProgress)
    let _ = try samplePersistedDownload(state: .enqueued)
    let download4 = try samplePersistedDownload(state: .inProgress)
    
    let recorder = queueManager.downloadQueue.record()
    var queue = try wait(for: recorder.next(), timeout: 1)
    XCTAssertEqual([download2, download4], queue!.map { $0.download })
    
    try database.write { db in
      download2.state = .complete
      try download2.save(db)
    }
    
    queue = try wait(for: recorder.next(), timeout: 1)
    XCTAssertEqual([download4, download1], queue!.map { $0.download })
  }
  
  func testDownloadQueueStreamDoesNotChangeIfAtCapacity() throws {
    let download1 = try samplePersistedDownload(state: .enqueued)
    let download2 = try samplePersistedDownload(state: .enqueued)
    
    let recorder = queueManager.downloadQueue.record()
    var queue = try wait(for: recorder.next(), timeout: 1)
    XCTAssertEqual([download1, download2], queue!.map { $0.download })
    
    let _ = try samplePersistedDownload(state: .enqueued)
    queue = try wait(for: recorder.next(), timeout: 1)
    XCTAssertEqual([download1, download2], queue!.map { $0.download })
  }
  
}
