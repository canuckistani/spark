// Copyright (c) 2013, Google Inc. Please see the AUTHORS file for details.
// All rights reserved. Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

/**
 * This library contains [BuilderManager] and the abstract [Builder] class.
 * These classes are used to batch process resource change events.
 */
library spark.builder;

import 'dart:async';

import 'package:logging/logging.dart';

import 'workspace.dart';
import 'jobs.dart';

final Logger _logger = new Logger('spark.builder');

/**
 * A [BuilderManager] listens for changes to a [Workspace], batches up those
 * changes, and feeds them into [Builder]s to be processed. A build - a
 * sequential execution of [Builder]s - can be a long running process. The build
 * is run in a [Job] in order to give good indication of progress to the user.
 */
class BuilderManager {
  final Workspace workspace;
  final JobManager jobManager;

  List<Builder> builders = [];

  List<ResourceChangeEvent> _events = [];

  Timer _timer;
  bool _buildRunning = false;

  BuilderManager(this.workspace, this.jobManager) {
    workspace.onResourceChange.listen(_handleChange);
  }

  bool get isRunning => _buildRunning;

  void _handleChange(ResourceChangeEvent event) {
    _events.add(event);

    if (!_buildRunning) {
      _startTimer();
    }
  }

  void _startTimer() {
    if (_timer != null) {
      _timer.cancel();
    }
    // Bundle up changes for ~50ms.
    _timer = new Timer(new Duration(milliseconds: 50), _runBuild);
  }

  void _runBuild() {
    ResourceChangeEvent event = _combineEvents(_events);
    Completer completer = new Completer();
    _BuildJob job = new _BuildJob(event, builders, completer);

    _events.clear();
    _buildRunning = true;

    jobManager.schedule(job);

    completer.future.then((_) {
      _buildRunning = false;
      if (_events.isNotEmpty) {
        _startTimer();
      }
    });
  }
}

/**
 * An abstract class that is given batched up resources changes to process.
 * Builders can be long running, and are executed in [Job]s.
 *
 * See also [BuilderManager].
 */
abstract class Builder {
  /**
   * Process a set of resource changes and complete the [Future] when finished.
   */
  Future build(ResourceChangeEvent changes);
}

class _BuildJob extends Job {
  final ResourceChangeEvent event;
  final List<Builder> builders;
  final Completer completer;

  _BuildJob(this.event, List<Builder> builders, this.completer) :
    this.builders = builders.toList(), super('Building…');

  Future<Job> run(ProgressMonitor monitor) {
    return Future.forEach(builders, (Builder builder) {
      builder.build(event);
    }).then((_) {
      completer.complete();
    }).catchError((e) {
      _logger.log(Level.SEVERE, 'Exception from builder', e);
      completer.complete();
    });
  }
}

ResourceChangeEvent _combineEvents(List<ResourceChangeEvent> events) {
  List<ChangeDelta> deltas = [];
  events.forEach((e) => deltas.addAll(e.changes));
  return new ResourceChangeEvent.fromList(deltas);
}