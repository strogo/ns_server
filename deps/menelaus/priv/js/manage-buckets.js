var validationMsgCounter = 0;

function setupFormValidation(form, url, callback) {
  var idleTime = 250;

  var oldValue;
  var inFlightXHR;
  var timeoutId;

  function showValidation() {
    if (!validationMsgCounter) {
      $('#validation_notice').show();
    }
    validationMsgCounter++;
  }

  function hideValidation() {
    validationMsgCounter--;
    if (!validationMsgCounter)
      $('#validation_notice').hide();
  }

  function timerFunction() {
    console.log("timerFunction!");

    timeoutId = undefined;
    inFlightXHR = $.ajax({
      type: 'POST',
      url: url,
      data: oldValue,
      dataType: 'json',
      error: xhrCallback,
      success: xhrCallback
    });
  }

  function xhrCallback(data, textStatus) {
    hideValidation();
    console.log("xhr done: ", data, textStatus);

    if (textStatus == 'success') {
      console.log("plan success");
      return callback('success', data);
    }

    var status = 0;
    try {
      status = data.status // can raise exception on IE sometimes
    } catch (e) {
      // ignore
    }
    if (status >= 200 && status < 300 && data.responseText == '') {
      console.log("inplain success");
      return callback('success');
    }

    if (status != 400 || textStatus != 'error') {
      return // onUnexpectedXHRError(data);
    }

    console.log("plain error");
    var errorsData = $.httpData(data, null, this);
    callback('error', errorsData);
  }

  function cancelXHR() {
    if (inFlightXHR) {
      Abortarium.abortRequest(inFlightXHR);
      inFlightXHR = null;
    }
  }

  var firstTime = true;

  function onPotentialChanges() {
    if (paused)
      return;

    var newValue = serializeForm(form);
    if (newValue == oldValue)
      return;
    oldValue = newValue;

    var wasFirstTime = firstTime;
    firstTime = false;

    showValidation();
    if (timeoutId) {
      hideValidation();         // because we already had in-progress validation
      console.log("aborting next validation");
      clearTimeout(timeoutId);
    }
    timeoutId = setTimeout(timerFunction, idleTime);
    cancelXHR();

    if (wasFirstTime) {
      showValidation();
      cancelTimeout();
      timerFunction();
    }
  }

  function cancelTimeout() {
    if (timeoutId) {
      hideValidation();
      clearTimeout(timeoutId);
      timeoutId = null;
    }
  }

  var observer = form.observePotentialChanges(onPotentialChanges);

  var paused = false;

  return {
    abort: function () {
      cancelTimeout();
      cancelXHR();
      observer.stopObserving();
    },
    pause: function () {
      if (paused)
        return;
      paused = true;
      showValidation();
      cancelXHR();
      cancelTimeout();
    },
    unpause: function () {
      paused = false;
      hideValidation();
      onPotentialChanges();
    }
  }
}

var BucketDetailsDialog = mkClass({
  initialize: function (initValues, isNew) {
    this.isNew = isNew;
    this.initValues = initValues;
    initValues['ramQuotaMB'] = Math.floor(initValues.quota.ram / 1048576);
    initValues['hddQuotaGB'] = Math.floor(initValues.quota.hdd / (1048576 * 1024));

    this.dialogID = 'bucket_details_dialog'

    var dialog = this.dialog = $('#' + this.dialogID);

    dialog.removeClass('editing').removeClass('creating');
    dialog.addClass(isNew ? 'creating' : 'editing');

    var bucketIsDefault = (initValues['name'] == 'default');
    if (!isNew) {
      dialog[(bucketIsDefault) ? 'addClass' : 'removeClass']('cannot-delete');
    }

    setBoolAttribute(dialog.find('[name=authType][value=none]'), 'disabled', bucketIsDefault);
    setBoolAttribute(dialog.find('[name=saslPassword]'), 'disabled', bucketIsDefault);

    setBoolAttribute(dialog.find('[name=name]'), 'disabled', !isNew);

    var oldBucketType;
    dialog.observePotentialChanges(function () {
      var newType = dialog.find('[name=bucketType]:checked').attr('value');
      if (newType == oldBucketType)
        return;
      oldBucketType = newType;
      var isPersistent = (newType == 'membase');
      dialog.find('.persistent-only')[isPersistent ? 'slideDown' : 'slideUp']('fast');
    });

    this.cleanups = [];

    var errorsCell = this.errorsCell = new Cell();
    errorsCell.subscribeValue($m(this, 'onValidationResult'));
    this.formValidator = setupFormValidation(dialog.find('form'),
                                             this.initValues.uri + '?just_validate=1',
                                             function (status, errors) {
                                               console.log("setting errors: ", errors);
                                               errorsCell.setValue(errors);
                                             });

    this.cleanups.push($m(this.formValidator, 'abort'));
  },

  bindWithCleanup: function (jq, event, callback) {
    jq.bind(event, callback);
    return function () {
      jq.unbind(event, callback);
    };
  },

  submit: function () {
    var self = this;

    var closeCleanup = self.bindWithCleanup(self.dialog.find('.jqmClose'),
                                            'click',
                                            function (e) {
                                              e.preventDefault();
                                              e.stopPropagation();
                                            });
    self.needBucketsRefresh = true;

    var nonPersistent = null;
    if (self.dialog.find('[name=bucketType]:checked').val() != 'membase') {
      nonPersistent = self.dialog.find('.persistent-only').find('input').filter(':not([disabled])');
      setBoolAttribute(nonPersistent, 'disabled', true);
    }

    self.formValidator.pause();

    postWithValidationErrors(self.initValues.uri, self.dialog.find('form'), function (data, status) {
      if (status == 'success') {
        BucketsSection.refreshBuckets(function () {
          self.needBucketsRefresh = false;
          enableForm();
          hideDialog(self.dialogID);
        });
        return;
      }

      enableForm();

      var errors = data[0]; // we expect errors as a hash in this case
      self.errorsCell.setValue(errors);
    });

    if (nonPersistent) {
      setBoolAttribute(nonPersistent, 'disabled', false);
    }

    var toDisable = self.dialog.find('input[type=text], input:not([type]), input[type=checkbox]')
      .filter(':not([disabled])')
      .add(self.dialog.find('button'));

    // we need to disable after post is sent, 'cause disabled inputs are not sent
    toDisable.add(self.dialog).css('cursor', 'wait');
    setBoolAttribute(toDisable, 'disabled', true);

    function enableForm() {
      self.formValidator.unpause();
      closeCleanup();
      setBoolAttribute(toDisable, 'disabled', false);
      toDisable.add(self.dialog).css('cursor', 'auto');
    }
  },
  startDialog: function () {
    var self = this;
    var form = this.dialog.find('form');

    setFormValues(form, self.initValues);

    var bucketTypeDisabled = !self.isNew;
    // this disabled memcached bucket type, 'cause backend is not
    // quite ready at this point
    if (!bucketTypeDisabled) {
      if (!(/(\?|&)enableMemcached=1/.exec(window.location.href)))
        bucketTypeDisabled = true;
    }
    setBoolAttribute(form.find('[name=bucketType]'), 'disabled', bucketTypeDisabled);

    self.cleanups.push(self.bindWithCleanup(form, 'submit', function (e) {
      e.preventDefault();
      self.submit();
    }));

    showDialog(this.dialogID, {
      onHide: function () {
        self.cleanup();
        if (self.needBucketsRefresh)
          BucketsSection.refreshBuckets();
      }
    });
  },
  cleanup: function () {
    _.each(this.cleanups, function (c) {
      c();
    });
  },

  renderGauge: function (jq, total, thisBucket, used) {
    var thisValue = thisBucket
    var formattedBucket = ViewHelpers.formatQuantity(thisBucket, null, null, ' ');

    if (_.isString(thisValue)) {
      formattedBucket = thisValue;
      thisValue = 0;
    }

    jq.find('.total').text(ViewHelpers.formatQuantity(total, null, null, ' '));
    var free = total - used - thisValue;
    jq.find('.free').text(ViewHelpers.formatQuantity(free, null, null, ' '));
    jq.find('.other').text(ViewHelpers.formatQuantity(used, null, null, ' '));
    jq.find('.this').text(formattedBucket);

    jq.find('.gauge .green').css('width', calculatePercent(used + thisValue, total) + '%');
    jq.find('.gauge .blue').css('width', calculatePercent(used, total) + '%');
  },

  renderOvercommitDiskGauge: function (jq, total, thisBucket, otherBuckets, otherData) {
    jq.filter('.normal').hide();
    jq = jq.filter('.overcommit').show();

    var formattedBucket = ViewHelpers.formatQuantity(thisBucket, null, null, ' ');

    var realTotal = thisBucket + otherBuckets + otherData;

    jq.find('.total').text(ViewHelpers.formatQuantity(total, null, null, ' '));
    var overcommitted = realTotal - total;
    jq.find('.overcommitted').text(ViewHelpers.formatQuantity(overcommitted, null, null, ' '));
    jq.find('.other').text(ViewHelpers.formatQuantity(otherBuckets, null, null, ' '));
    jq.find('.other-data').text(ViewHelpers.formatQuantity(otherData, null, null,' '));
    jq.find('.this').text(formattedBucket);

    jq.find('.gauge .green').css('width', calculatePercent(total, realTotal) + '%');
    jq.find('.gauge .blue').css('width', calculatePercent(otherData + otherBuckets, realTotal) + '%');
    jq.find('.gauge .yellow').css('width', calculatePercent(otherData, realTotal) + '%');
  },

  renderDiskGauge: function (jq, total, thisBucket, otherBuckets, otherData) {
    if (thisBucket + otherBuckets + otherData > total)
      return this.renderOvercommitDiskGauge(jq, total, thisBucket, otherBuckets, otherData);

    jq.filter('.overcommit').hide();
    jq = jq.filter('.normal').show();

    var formattedBucket = ViewHelpers.formatQuantity(thisBucket, null, null, ' ');

    jq.find('.total').text(ViewHelpers.formatQuantity(total, null, null, ' '));
    var free = total - otherData - thisBucket - otherBuckets;
    jq.find('.free').text(ViewHelpers.formatQuantity(free, null, null, ' '));
    jq.find('.other').text(ViewHelpers.formatQuantity(otherBuckets, null, null, ' '));
    jq.find('.other-data').text(ViewHelpers.formatQuantity(otherData, null, null,' '));
    jq.find('.this').text(formattedBucket);

    jq.find('.gauge .green').css('width', calculatePercent(otherData + otherBuckets + thisBucket, total) + '%');
    jq.find('.gauge .blue').css('width', calculatePercent(otherData + otherBuckets, total) + '%');
    jq.find('.gauge .yellow').css('width', calculatePercent(otherData, total) + '%');
  },

  renderError: function (field, error) {
    this.dialog.find('.error-container.err-' + field).text(error || '')[error ? 'addClass' : 'removeClass']('active');
    this.dialog.find('[name=' + field + ']')[error ? 'addClass' : 'removeClass']('invalid');
  },

  // this updates our gauges and errors
  // we don't use it to set input values, 'cause for the later we need to do it once
  onValidationResult: function (result) {
    var self = this;
    result = result || {};
    // if (!result)                // TODO: handle it
    //   return;

    var summaries = result.summaries || {};
    var ramSummary = summaries.ramSummary;
    var hddSummary = summaries.hddSummary;

    var ramGauge = self.dialog.find(".size-gauge.for-ram");
    if (ramSummary)
      self.renderGauge(ramGauge,
                       ramSummary.total,
                       ramSummary.thisAlloc,
                       ramSummary.otherBuckets);
    ramGauge.css('visibility', ramSummary ? 'visible' : 'hidden');

    var hddGauge = self.dialog.find('.size-gauge.for-hdd');
    if (hddSummary)
      self.renderDiskGauge(hddGauge,
                           hddSummary.total,
                           hddSummary.thisAlloc,
                           hddSummary.otherBuckets,
                           hddSummary.otherData);
    hddGauge.css('visibility', hddSummary ? 'visible' : 'hidden');

    var knownFields = ('name ramQuotaMB hddQuotaGB replicaNumber proxyPort').split(' ');
    var errors = result.errors || {};
    _.each(knownFields, function (name) {
      self.renderError(name, errors[name]);
    });
  }
});

var BucketsSection = {
  cells: {},
  init: function () {
    var self = this;
    var cells = self.cells;

    cells.mode = DAO.cells.mode;

    cells.detailsPageURI = new Cell(function (poolDetails) {
      return poolDetails.buckets.uri;
    }).setSources({poolDetails: DAO.cells.currentPoolDetails});

    self.settingsWidget = new MultiDrawersWidget({
      hashFragmentParam: "buckets",
      template: "bucket_settings",
      placeholderCSS: '#buckets .settings-placeholder',
      elementsKey: 'name',
      drawerCellName: 'settingsCell',
      idPrefix: 'settingsRowID',
      actionLink: 'visitBucket',
      actionLinkCallback: function () {
        ThePage.ensureSection('buckets');
      },
      valueTransformer: function (bucketInfo, bucketSettings) {
        var rv = _.extend({}, bucketInfo, bucketSettings);
        delete rv.settingsCell;
        return rv;
      }
    });

    var poolDetailsValue;
    DAO.cells.currentPoolDetails.subscribeValue(function (v) {
      if (!v)
        return;

      poolDetailsValue = v;
    });

    var bucketsListTransformer = function (values) {
      self.buckets = values;
      _.each(values, function (bucket) {
        if (bucket.bucketType == 'memcache') {
          bucket.bucketTypeName = 'Memcached';
        } else if (bucket.bucketType == 'membase') {
          bucket.bucketTypeName = 'Membase';
        } else {
          bucket.bucketTypeName = bucket.bucketType;
        }

        bucket.serversCount = poolDetailsValue.nodes.length;
        bucket.ramQuota = bucket.quota.ram;
        var storageTotals = poolDetailsValue.storageTotals
        bucket.totalRAMSize = storageTotals.ram.total;
        bucket.totalRAMUsed = bucket.basicStats.memUsed;
        bucket.otherRAMSize = storageTotals.ram.used - bucket.totalRAMUsed;
        bucket.totalRAMFree = storageTotals.ram.total - storageTotals.ram.used;

        bucket.RAMUsedPercent = calculatePercent(bucket.totalRAMUsed, bucket.totalRAMSize);
        bucket.RAMOtherPercent = calculatePercent(bucket.totalRAMUsed + bucket.otherRAMSize, bucket.totalRAMSize);

        bucket.totalDiskSize = storageTotals.hdd.total;
        bucket.totalDiskUsed = bucket.basicStats.diskUsed;
        bucket.otherDiskSize = storageTotals.hdd.used - bucket.totalDiskUsed;
        bucket.totalDiskFree = storageTotals.hdd.total - storageTotals.hdd.used;

        bucket.diskUsedPercent = calculatePercent(bucket.totalDiskUsed, bucket.totalDiskSize);
        bucket.diskOtherPercent = calculatePercent(bucket.otherDiskSize + bucket.totalDiskUsed, bucket.totalDiskSize);
      });
      values = self.settingsWidget.valuesTransformer(values);
      return values;
    }
    cells.detailedBuckets = new Cell(function (pageURI) {
      return future.get({url: pageURI}, bucketsListTransformer, this.self.value);
    }).setSources({pageURI: cells.detailsPageURI});

    renderCellTemplate(cells.detailedBuckets, 'bucket_list');

    self.settingsWidget.hookRedrawToCell(cells.detailedBuckets);

    $('.create-bucket-button').live('click', function (e) {
      e.preventDefault();
      BucketsSection.startCreate();
    });

    $('#bucket_details_dialog .delete_button').bind('click', function (e) {
      e.preventDefault();
      BucketsSection.startRemovingBucket();
    });
  },
  buckets: null,
  refreshBuckets: function (callback) {
    var cell = this.cells.detailedBuckets;
    if (callback) {
      cell.changedSlot.subscribeOnce(callback);
    }
    cell.invalidate();
  },
  withBucket: function (uri, body) {
    if (!this.buckets)
      return;
    var buckets = this.buckets || [];
    var bucketInfo = _.detect(buckets, function (info) {
      return info.uri == uri;
    });

    if (!bucketInfo) {
      console.log("Not found bucket for uri:", uri);
      return null;
    }

    return body.call(this, bucketInfo);
  },
  findBucket: function (uri) {
    return this.withBucket(uri, function (r) {return r});
  },
  showBucket: function (uri) {
    ThePage.ensureSection('buckets');
    // we don't care about value, but we care if it's defined
    DAO.cells.currentPoolDetailsCell.getValue(function () {
      BucketsSection.withBucket(uri, function (bucketDetails) {
        BucketsSection.currentlyShownBucket = bucketDetails;
        var initValues = _.extend({}, bucketDetails, bucketDetails.settingsCell.value);
        var dialog = new BucketDetailsDialog(initValues, false);
        dialog.startDialog();
      });
    });
  },
  startFlushCache: function (uri) {
    hideDialog('bucket_details_dialog_container');
    this.withBucket(uri, function (bucket) {
      renderTemplate('flush_cache_dialog', {bucket: bucket});
      showDialog('flush_cache_dialog_container');
    });
  },
  completeFlushCache: function (uri) {
    hideDialog('flush_cache_dialog_container');
    this.withBucket(uri, function (bucket) {
      $.post(bucket.flushCacheUri);
    });
  },
  getPoolNodesCount: function () {
    return DAO.cells.currentPoolDetails.value.nodes.length;
  },
  onEnter: function () {
    this.refreshBuckets();
  },
  navClick: function () {
    this.onLeave();
    this.onEnter();
  },
  onLeave: function () {
    this.settingsWidget.reset();
  },
  startCreate: function () {
    var totals = DAO.cells.currentPoolDetails.value.storageTotals;
    if (totals.ram.quotaTotal == totals.ram.quotaUsed || totals.hdd.quotaTotal == totals.hdd.quotaUsed) {
      alert('TODO: No free quota left!')
      return;
    }
    var initValues = {uri: '/pools/default/buckets',
                      bucketType: 'membase',
                      authType: 'sasl', //TODO: what's best default ?
                      quota: {ram: totals.ram.quotaTotal - totals.ram.quotaUsed,
                              hdd: totals.hdd.quotaTotal - totals.hdd.quotaUsed},
                      replicaNumber: 1}
    var dialog = new BucketDetailsDialog(initValues, true);
    dialog.startDialog();
  },
  // TODO: currently inaccessible from UI
  startRemovingBucket: function () {
    if (!this.currentlyShownBucket)
      return;

    $('#bucket_details_dialog').addClass('overlayed');
    $('#bucket_remove_dialog .bucket_name').text(this.currentlyShownBucket.name);
    showDialog('bucket_remove_dialog', {
      onHide: function () {
        $('#bucket_details_dialog').removeClass('overlayed');
      }
    });
  },
  // TODO: currently inaccessible from UI
  removeCurrentBucket: function () {
    var self = this;

    var bucket = self.currentlyShownBucket;
    if (!bucket)
      return;

    var spinner = overlayWithSpinner('#bucket_remove_dialog');
    var modal = new ModalAction();
    $.ajax({
      type: 'DELETE',
      url: self.currentlyShownBucket.uri,
      success: continuation,
      errors: continuation
    });
    return;

    function continuation() {
      self.refreshBuckets(continuation2);
    }

    function continuation2() {
      spinner.remove();
      modal.finish();
      hideDialog('bucket_details_dialog');
      hideDialog('bucket_remove_dialog');
    }
  }
};

configureActionHashParam("editBucket", $m(BucketsSection, 'showBucket'));

$(function () {
  var oldIsSasl;
  var dialog = $('#bucket_details_dialog')
  dialog.observePotentialChanges(function () {
    var saslSelected = $('#bucket_details_sasl_selected')[0];
    if (!saslSelected) // might happen just before page unload
      return;
    var isSasl = saslSelected.checked;
    if (oldIsSasl != null && isSasl == oldIsSasl)
      return;
    oldIsSasl = isSasl;

    setBoolAttribute(dialog.find('.for-sasl-password-input input'), 'disabled', !isSasl);
    setBoolAttribute(dialog.find('.for-proxy-port input'), 'disabled', isSasl);
  });
});
