/*
 * Copyright 2018 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <memory>
#include <string>

#include "Firestore/core/src/firebase/firestore/auth/token.h"
#include "Firestore/core/src/firebase/firestore/remote/connectivity_monitor.h"
#include "Firestore/core/src/firebase/firestore/remote/grpc_connection.h"
#include "Firestore/core/src/firebase/firestore/util/async_queue.h"
#include "Firestore/core/src/firebase/firestore/util/executor_std.h"
#include "Firestore/core/test/firebase/firestore/util/grpc_stream_tester.h"
#include "absl/memory/memory.h"
#include "gtest/gtest.h"

namespace firebase {
namespace firestore {
namespace remote {

using auth::Token;
using auth::User;
using core::DatabaseInfo;
using model::DatabaseId;
using util::AsyncQueue;
using util::GrpcStreamTester;
using util::Status;
using util::StatusOr;
using util::internal::ExecutorStd;
using NetworkStatus = ConnectivityMonitor::NetworkStatus;

namespace {

class MockConnectivityMonitor : public ConnectivityMonitor {
 public:
  MockConnectivityMonitor(AsyncQueue* worker_queue)
      : ConnectivityMonitor{worker_queue} {
    SetInitialStatus(NetworkStatus::Available);
  }

  void set_status(NetworkStatus new_status) {
    MaybeInvokeCallbacks(new_status);
  }
};

bool IsConnectivityChange(const Status& status) {
  return status.code() == FirestoreErrorCode::Unavailable &&
         status.error_message() == "Network connectivity changed";
}

class ConnectivityObserver : public GrpcStreamObserver {
 public:
  void OnStreamStart() override {
  }
  void OnStreamRead(const grpc::ByteBuffer& message) override {
  }
  void OnStreamFinish(const util::Status& status) override {
    if (IsConnectivityChange(status)) {
      ++connectivity_change_count_;
    }
  }

  int connectivity_change_count() const {
    return connectivity_change_count_;
  }
  int connectivity_change_count_ = 0;
};

}  // namespace

class GrpcConnectionTest : public testing::Test {
 public:
  GrpcConnectionTest() {
    auto connectivity_monitor_owning =
        absl::make_unique<MockConnectivityMonitor>(&tester->worker_queue());
    connectivity_monitor = connectivity_monitor_owning.get();
    tester = absl::make_unique<GrpcStreamTester>(
        std::move(connectivity_monitor_owning));
  }

  void SetNetworkStatus(NetworkStatus new_status) {
    tester->worker_queue().EnqueueBlocking(
        [&] { connectivity_monitor->set_status(new_status); });
    // Make sure the callback executes.
    tester->worker_queue().EnqueueBlocking([] {});
  }

  std::unique_ptr<GrpcStreamTester> tester;
  MockConnectivityMonitor* connectivity_monitor = nullptr;
};

TEST_F(GrpcConnectionTest, GrpcStreamsNoticeChangeInConnectivity) {
  ConnectivityObserver observer;

  auto stream = tester->CreateStream(&observer);
  stream->Start();
  EXPECT_EQ(observer.connectivity_change_count(), 0);

  SetNetworkStatus(NetworkStatus::Available);
  // Same status shouldn't trigger a callback.
  EXPECT_EQ(observer.connectivity_change_count(), 0);

  tester->KeepPollingGrpcQueue();
  SetNetworkStatus(NetworkStatus::Unavailable);
  EXPECT_EQ(observer.connectivity_change_count(), 1);
}

TEST_F(GrpcConnectionTest, GrpcStreamingCallsNoticeChangeInConnectivity) {
  int change_count = 0;
  auto streaming_call = tester->CreateStreamingReader();
  streaming_call->Start(
      [&](const StatusOr<std::vector<grpc::ByteBuffer>>& result) {
        if (IsConnectivityChange(result.status())) {
          ++change_count;
        }
      });

  SetNetworkStatus(NetworkStatus::Available);
  // Same status shouldn't trigger a callback.
  EXPECT_EQ(change_count, 0);

  tester->KeepPollingGrpcQueue();
  SetNetworkStatus(NetworkStatus::AvailableViaCellular);
  EXPECT_EQ(change_count, 1);
}

TEST_F(GrpcConnectionTest, ConnectivityChangeWithSeveralActiveCalls) {
  int changes_count = 0;

  auto foo = tester->CreateStreamingReader();
  foo->Start([&](const StatusOr<std::vector<grpc::ByteBuffer>>&) {
    foo.reset();
    ++changes_count;
  });

  auto bar = tester->CreateStreamingReader();
  bar->Start([&](const StatusOr<std::vector<grpc::ByteBuffer>>&) {
    bar.reset();
    ++changes_count;
  });

  auto baz = tester->CreateStreamingReader();
  baz->Start([&](const StatusOr<std::vector<grpc::ByteBuffer>>&) {
    baz.reset();
    ++changes_count;
  });

  tester->KeepPollingGrpcQueue();
  EXPECT_NO_THROW(SetNetworkStatus(NetworkStatus::Unavailable));
  EXPECT_EQ(changes_count, 3);
}

}  // namespace remote
}  // namespace firestore
}  // namespace firebase