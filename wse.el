;;; wse.el --- Show Wordpress statistics -*- lexical-binding: t -*-

;; Copyright (C) 2025 Free Software Foundation, Inc.

;; Author: Lars Magne Ingebrigtsen <larsi@gnus.org>

;; wse is free software; you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; wse is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
;; or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public
;; License for more details.

;;; Commentary:

;;; Code:

(require 'cl-lib)
(require 'eplot)
(require 'url-domsuf)

(defvar wse-font "sans-serif"
  "Font family to use in buffer and charts.")

(defface wse
  `((t :family ,wse-font))
  "The face to use in wse buffers.")

(defvar wse-blogs nil
  "A list of blogs to collect statistics from.
This should be a list of names (like \"foo.org\" and not URLs.")

(defvar wse-entries 12
  "The number of entries to display.")

;; Internal variables.
(defvar wse--db nil)
(defvar wse--filling-country nil)
(defvar wse--timer nil)

(defun wse ()
  "Display Wordpress statistics."
  (interactive)
  (switch-to-buffer "*WSE*")
  (wse--render))

(defun wse-update-automatically ()
  "Update *WSE* automatically periodically."
  (interactive)
  (when wse--timer
    (cancel-timer wse-timer))
  (setq wse--timer (run-at-time 60 (* 60 5) #'wse--update)))

;; This is a separate function instead of a lambda so that it's easier
;; to find in `M-x list-timers'.
(defun wse--update ()
  (when-let ((idle (current-idle-time))
	     (buffer (get-buffer "*WSE*")))
    (when (> (time-convert (time-since idle) 'integer) 20)
      (with-current-buffer buffer
	(wse-revert t)))))

;; Helper functions.

(defun wse--bot-p (user-agent)
  (let ((case-fold-search t))
    (string-match-p "bot/\\|spider\\b" user-agent)))

(defun wse--host (url)
  (url-host (url-generic-parse-url url)))

(defun wse--url-p (string)
  (and (and (stringp string))
       (not (zerop (length string)))
       (string-match-p "\\`[a-z]+:" string)))

(defun wse--media-p (click)
  (string-match "[.]\\(mp4\\|png\\|jpg\\|jpeg\\|webp\\|webp\\)\\'" click))

(defun wse--countrify (code name)
  (if (= (length code) 2)
      ;; Convert the country code into a Unicode flag.
      (concat (string (+ #x1f1a5 (elt code 0)) (+ #x1f1a5 (elt code 1)))
	      " " name)
    name))

(defun wse--pretty-url (string)
  (replace-regexp-in-string "\\`[a-z]+://" "" string))

(defun wse--possibly-buttonize (string)
  (if (wse--url-p string)
      (buttonize (wse--pretty-url string) #'wse--browse string string)
    string))

(defun wse--time (time)
  (format-time-string "%Y-%m-%d %H:%M:%S" time))

(defun wse--24h ()
  (wse--time (- (time-convert (current-time) 'integer)
		(* 60 60 24))))

(defun wse--future ()
  "9999-12-12 23:59:00")

(defun wse--convert-time (time)
  "Convert TIME from GMT/Z/UTC to local time."
  (wse--time
   (encode-time (iso8601-parse (concat (string-replace " " "T" time) "Z")))))

(defun wse--browse (url)
  (let ((browse-url-browser-function
	 (if (and (wse--media-p url)
		  (not (string-match "[.]mp4\\'" url)))
	     browse-url-browser-function
	   browse-url-secondary-browser-function)))
    (browse-url url)))

(defun wse--get-domain (host)
  "Return the shortest domain that refers to an entity.
I.e., \"google.com\" or \"google.co.uk\"."
  (let* ((bits (reverse (split-string host "[.]")))
	 (domain (pop bits)))
    (cl-loop while (and bits
			(not (url-domsuf-cookie-allowed-p domain)))
	     do (setq domain (concat (pop bits) "." domain)))
    domain))

(defun wse-sel (statement &rest args)
  (sqlite-select wse--db statement args))

(defun wse-exec (statement &rest args)
  (sqlite-execute wse--db statement args))

;; Update data.

(defun wse--poll-blogs (&optional callback)
  (let ((blogs wse-blogs)
	(data nil)
	func)
    (setq func
	  (lambda ()
	    (let* ((blog (pop blogs))
		   (ids (or (car
			     (wse-sel "select last_id, last_comment_id from blogs where blog = ?"
				      blog))
			    '(0 0)))
		   (url-request-method "POST")
		   (url-request-extra-headers
		    '(("Content-Type" . "application/x-www-form-urlencoded")
		      ("Charset" . "UTF-8")))
		   (url-request-data
		    (mm-url-encode-www-form-urlencoded
		     `(("from_id" . ,(format "%d" (car ids)))
		       ("from_comment_id" . ,(format "%d" (or (cadr ids) 0)))
		       ("password" . ,(auth-info-password
				       (car
					(auth-source-search
					 :max 1
					 :user "wse"
					 :host blog
					 :require '(:user :secret)
					 :create t))))))))
	      (url-retrieve
	       (format "https://%s/wp-content/plugins/wse/data.php" blog)
	       (lambda (status)
		 (goto-char (point-min))
		 (unwind-protect
		     (and (search-forward "\n\n" nil t)
			  (not (plist-get status :error))
			  (push (cons blog (json-parse-buffer)) data))
		   (kill-buffer (current-buffer))
		   (if blogs
		       (funcall func)
		     (wse--update-data data callback))))
	       nil t))))
    (funcall func)))      

(defun wse--update-data (data &optional callback)
  (cl-loop for (blog . elems) in data
	   do (cl-loop for elem across (gethash "data" elems)
		       for (id time click page referrer ip user-agent title) =
		       (cl-coerce elem 'list)
		       unless (wse--bot-p user-agent)
		       do
		       (wse--insert-data blog (wse--convert-time time)
					 click page referrer ip
					 user-agent title)
		       (wse--update-id blog id))
	   do (wse--store-comments blog (gethash "comments" elems)))

  (unless wse--filling-country
    (wse--fill-country))
  (wse--possibly-summarize-history)
  (when callback
    (funcall callback)))

(defun wse--update-id (blog id)
  (if (wse-sel "select last_id from blogs where blog = ?" blog)
      (wse-exec "update blogs set last_id = ? where blog = ?" id blog)
    (wse-exec "insert into blogs(blog, last_id) values(?, ?)" blog id)))

(defun wse--initialize ()
  (unless wse--db
    (setq wse--db (sqlite-open
		   (expand-file-name "wse.sqlite" user-emacs-directory)))

    ;; Keeping track of ids per blog.
    (wse-exec "create table if not exists blogs (blog text primary key, last_id integer, last_comment_id integer)")

    ;; Statistics.
    (wse-exec "create table if not exists views (id integer primary key, blog text, date date, time datetime, page text, ip text, user_agent text, title text, country text, referrer text)")
    (wse-exec "create table if not exists referrers (id integer primary key, blog text, time datetime, referrer text, page text)")
    (wse-exec "create table if not exists clicks (id integer primary key, blog text, time datetime, click text, domain text, page text)")

    ;; History.
    (wse-exec "create table if not exists history (id integer primary key, blog text, date date, views integer, visitors integer, clicks integer, referrers integer)")
    (wse-exec "create unique index if not exists historyidx1 on history(blog, date)")

    ;; Countries.
    (wse-exec "create table if not exists country_counter (id integer)")
    (unless (wse-sel "select * from country_counter")
      (wse-exec "insert into country_counter values (0)"))
    (wse-exec "create table if not exists countries (code text primary key, name text)")

    ;; Comments.
    (wse-exec "create table if not exists comments (blog text, id integer, post_id integer, time datetime, author text, email text, url text, content text, status text)")
    (wse-exec "create unique index if not exists commentsidx1 on comments(blog, id)")))

(defun wse--insert-data (blog time click page referrer ip user-agent title)
  ;; Titles aren't set for clicks.
  (when (eq title :null)
    (setq title ""))
  (when (wse--url-p page)
    (if (wse--url-p click)
	;; Register a click if it's not going to the current blog, or
	;; whether it's going to a media URL of some kind (image/mp4/etc).
	(when (or (not (equal (wse--host click) blog))
		  (string-match "/wp-contents/uploads/" click)
		  (wse--media-p click))
	  (wse-exec
	   "insert into clicks(blog, time, click, domain, page) values(?, ?, ?, ?, ?)"
	   blog time click (wse--host click) page))
      ;; Insert into views.
      (wse-exec
       "insert into views(blog, date, time, page, ip, user_agent, title, country, referrer) values(?, ?, ?, ?, ?, ?, ?, ?, ?)"
       blog (substring time 0 10) time page ip user-agent title ""
       referrer)
      ;; Check whether to register a referrer.
      (when (and (wse--url-p referrer)
		 (not (equal (wse--host referrer) blog)))
	(wse-exec
	 "insert into referrers(blog, time, referrer, page) values(?, ?, ?, ?)"
	 blog time referrer page)))))

(defun wse--store-comments (blog comments)
  (cl-loop for comment across comments
	   do (wse-exec "update blogs set last_comment_id = ? where blog = ?"
			(gethash "comment_id" comment)
			blog)
	   if (wse-sel "select id from comments where id = ? and blog = ?"
		       (gethash "comment_id" comment)
		       blog)
	   ;; We're selecting on comment_id now, so we'll never get
	   ;; updated statuses...
	   do (wse-exec "update comments set status = ? where blog = ? and id = ?"
			(gethash "comment_approved" comment)
			blog
			(gethash "comment_id" comment))
	   else
	   do (wse-exec "insert into comments(blog, id, post_id, time, author, email, url, content, status) values(?, ?, ?, ?, ?, ?, ?, ?, ?)"
			blog
			(gethash "comment_id" comment)
			(gethash "comment_post_id" comment)
			(wse--convert-time
			 (gethash "comment_date_gmt" comment))
			(gethash "comment_author" comment)
			(gethash "comment_author_email" comment)
			(gethash "comment_url" comment)
			(gethash "comment_content" comment)
			(gethash "comment_approved" comment))))

(defun wse--possibly-summarize-history ()
  (let ((max (caar (wse-sel "select max(date) from history"))))
    (when (or (not max)
	      (string< max (substring (wse--time (current-time)) 0 10)))
      (wse--summarize-history))))

(defun wse--summarize-history ()
  (dolist (blog wse-blogs)
    (cl-loop with max-date = (caar (wse-sel "select max(date) from views where blog = ?"
					    blog))
	     for (date views visitors) in
	     (wse-sel "select date, count(date), count(distinct ip) from views where date < ? and blog = ? group by date order by date"
		      max-date blog)
	     unless (wse-sel "select date from history where blog = ? and date = ?"
			     blog date)
	     do (wse-exec "insert into history(blog, date, views, visitors, clicks, referrers) values (?, ?, ?, ?, ?, ?)"
			  blog date views visitors
			  (caar (wse-sel "select count(*) from clicks where blog = ? and time between ? and ?"
					 blog (concat date " 00:00:00")
					 (concat date " 23:59:59")))
			  (caar (wse-sel "select count(*) from referrers where blog = ? and time between ? and ?"
					 blog (concat date " 00:00:00")
					 (concat date " 23:59:59")))))))

(defun wse--fill-country ()
  (setq wse--filling-country t)
  (let ((id (or (caar (wse-sel "select id from country_counter"))
		0))
	func)
    (setq func
	  (lambda ()
	    (let ((next
		   (caar (wse-sel "select min(id) from views where id > ?"
				  id))))
	      (if (not next)
		  (setq wse--filling-country nil)
		(url-retrieve
		 (format "http://ip-api.com/json/%s"
			 (caar (wse-sel "select ip from views where id = ?"
					next)))
		 (lambda (status)
		   (goto-char (point-min))
		   (let ((country-code "-")
			 (country-name nil))
		     (when (and (not (plist-get status :error))
				(search-forward "\n\n" nil t))
		       (let ((json (json-parse-buffer)))
			 (when (equal (gethash "status" json) "success")
			   (setq country-code (gethash "countryCode" json)
				 country-name (gethash "country" json)))))
		     (kill-buffer (current-buffer))
		     (wse-exec "update views set country = ? where id = ?"
			       country-code next)
		     (wse-exec "update country_counter set id = ?" next)
		     (when (and country-name
				(not (wse-sel "select * from countries where code = ?"
					      country-code)))
		       (wse-exec "insert into countries(code, name) values (?, ?)"
				 country-code country-name))
		     (setq id next)
		     ;; The API is rate limited at 45 per minute, so
		     ;; poll max 30 times per minute.
		     (run-at-time 2 nil func)))
		 nil t)))))
    (funcall func)))

;; Modes and command for modes.

(define-derived-mode wse-mode special-mode "WSE"
  "Major mode for listing Wordpress statistics."
  :interactive nil
  (setq truncate-lines t))

(defvar-keymap wse-mode-map
  :parent button-map
  "g" #'wse-revert
  "d" #'wse-view-date
  "q" #'bury-buffer
  "v" #'wse-view-details)

(defun wse-revert (&optional silent)
  "Update the current buffer."
  (interactive nil wse-mode)
  (unless silent
    (message "Updating..."))
  (let ((buffer (current-buffer)))
    (wse--poll-blogs
     (lambda ()
       (when (buffer-live-p buffer)
	 (with-current-buffer buffer
	   (wse--render)
	   (unless silent
	     (message "Updating...done"))))))))

(defun wse-view-date (date)
  (interactive
   (list (completing-read
	  "Date to show: "
	  (mapcar #'car (wse-sel "select distinct date from history order by date"))))
   wse-mode)
  (switch-to-buffer "*WSE Date*")
  (let ((inhibit-read-only t))
    (erase-buffer)
    (special-mode)
    (wse--view-total-views nil date)
    (goto-char (point-max))
    (insert "\n")
    (wse--view-total-referrers nil date)
    (goto-char (point-max))
    (insert "\n")
    (wse--view-total-clicks nil date)
    (goto-char (point-max))
    (insert "\n")
    (wse--view-total-countries nil date)
    (goto-char (point-min))))

(defun wse-view-details ()
  "View details of the URL under point."
  (interactive nil wse-mode)
  (cond
   ((eq (vtable-current-column) 1)
    (when-let ((data (elt (vtable-current-object) (vtable-current-column)))
	       (url (get-text-property 1 'help-echo data)))
      (wse--view-page-details url)))
   ((eq (vtable-current-column) 3)
    (when-let ((urls (elt (vtable-current-object) 4)))
      (when (listp urls)
	(wse--view-referrer-details urls))))))

(defun wse--view-page-details (url)
  (switch-to-buffer "*WSE Details*")
  (let ((inhibit-read-only t))
    (erase-buffer)
    (special-mode)
    (setq truncate-lines t)
    (make-vtable
     :face 'wse
     :columns '((:name "Time")
		(:name "IP" :max-width 20)
		(:name "Referrer" :max-width 40)
		(:name "Country")
		(:name "User-Agent"))
     :objects (wse-sel "select time, ip, referrer, country, user_agent from views where time > ? and page = ? order by time"
		       (wse--24h) url)
     :getter
     (lambda (elem column _vtable)
       (elt elem column))
     :keymap wse-mode-map)))

(defun wse--view-referrer-details (urls)
  (switch-to-buffer "*WSE Details*")
  (let ((inhibit-read-only t))
    (erase-buffer)
    (special-mode)
    (setq truncate-lines t)
    (make-vtable
     :face 'wse
     :columns '((:name "Time")
		(:name "Referrer" :max-width 40)
		(:name "Page"))
     :objects (apply #'wse-sel
		     (format "select time, referrer, page from referrers where time > ? and referrer in (%s) order by time"
			     (mapconcat (lambda (_) "?") urls ","))
		     (wse--24h) urls)
     :getter
     (lambda (elem column vtable)
       (if (equal (vtable-column vtable column) "Page")
	   (wse--possibly-buttonize (elt elem column))
	 (elt elem column)))
     :keymap wse-mode-map)))

(defun wse--render ()
  (wse--initialize)
  (wse-mode)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (make-vtable
     :face 'wse
     :use-header-line nil
     :columns '((:name "" :align 'right :min-width "70px")
		(:name "Posts & Pages" :width "600px")
		(:name "" :align 'right :min-width "70px")
		(:name "Referrers" :width 45))
     :objects (wse--get-page-table-data)
     :getter
     (lambda (elem column vtable)
       (if (equal (vtable-column vtable column) "Referrers")
	   (wse--possibly-buttonize (elt elem column))
	 (elt elem column)))
     :keymap wse-mode-map)

    (goto-char (point-max))
    (insert "\n")
    (make-vtable
     :face 'wse
     :use-header-line nil
     :columns '((:name "" :align 'right :min-width "70px")
		(:name "Clicks" :width "600px")
		(:name "" :align 'right :min-width "70px")
		(:name "Countries" :width 45))
     :objects (wse--get-click-table-data)
     :getter
     (lambda (elem column vtable)
       (cond
	((equal (vtable-column vtable column) "Clicks")
	 (wse--possibly-buttonize (elt elem column)))
	((equal (vtable-column vtable column) "Countries")
	 (wse--countrify (elt elem 4) (elt elem column)))
	(t
	 (elt elem column))))
     :keymap wse-mode-map)

    (goto-char (point-max))
    (insert "\n")
    (make-vtable
     :face 'wse
     :use-header-line nil
     :columns '((:name "Blog" :max-width 20)
		(:name "Status")
		(:name "Author")
		(:name "Comment" :max-width 60))
     :objects (wse-sel "select blog, status, author, content, post_id from comments where time > ? order by time desc"
		       (wse--time (- (time-convert (current-time) 'integer)
				     (* 4 60 60 24))))
     :getter
     (lambda (elem column vtable)
       (cond
	((equal (vtable-column vtable column) "Status")
	 (if (equal (elt elem column) "1")
	     ""
	   (elt elem column)))
	((equal (vtable-column vtable column) "Comment")
	 (let ((url (format "https://%s/?p=%d"
			    (elt elem 0) (elt elem 4))))
	   (buttonize (elt elem column) #'wse--browse
		      url url)))
	(t
	 (elt elem column))))
     :keymap wse-mode-map)

    (goto-char (point-max))
    (insert "\n")
    (make-vtable
     :face 'wse
     :use-header-line nil
     :columns '((:name "Last Update"))
     :objects (list (message-make-date))
     :keymap wse-mode-map)

    (goto-char (point-min))
    (insert "\n")
    (goto-char (point-min))
    (wse--plot-history)
    (wse--plot-blogs-today)
    (insert "\n")))

(defun wse--get-page-table-data ()
  (let* ((time (wse--24h))
	 (pages
	  (wse-sel "select count(page), title, page from views where time > ? group by page order by count(page) desc limit ?"
		   time wse-entries))
	 (referrers
	  (wse--transform-referrers
	   (wse-sel "select count(referrer), referrer from referrers where time > ? group by referrer order by count(referrer) desc"
		    time)
	   t)))
    (nconc
     (cl-loop for i from 0 upto (1- wse-entries)
	      for page = (elt pages i)
	      collect
	      (append (if page
			  (list (nth 0 page)
				(buttonize
				 (cond
				  ((wse--url-p (nth 1 page))
				   (wse--pretty-url (nth 1 page)))
				  ((zerop (length (nth 1 page)))
				   (wse--pretty-url (nth 2 page)))
				  (t
				   (nth 1 page)))
				 #'wse--browse (elt page 2)
				 (elt page 2)))
			(list "" ""))
		      (or (elt referrers i) (list "" ""))))
     (list
      (list
       (caar (wse-sel "select count(*) from views where time > ?" time))
       (buttonize "Total Views" #'wse--view-total-views)
       (caar (wse-sel "select count(*) from referrers where time > ?" time))
       (buttonize "Total Referrers" #'wse--view-total-referrers))))))

(defun wse--get-click-table-data ()
  (let* ((time (wse--24h))
	 (clicks
	  (wse-sel "select count(domain), domain, count(distinct click), click from clicks where time > ? group by domain order by count(domain) desc limit ?"
		   time wse-entries))
	 (countries
	  (wse-sel "select count(country), name, code from views, countries where time > ? and views.country = countries.code group by country order by count(country) desc limit ?"
		   time wse-entries)))
    (nconc
     (cl-loop for i from 0 upto (1- wse-entries)
	      for click = (elt clicks i)
	      collect
	      (append (if click
			  (list (car click)
				(if (= (nth 2 click) 1)
				    (nth 3 click)
				  (buttonize
				   (concat "🔽 " (cadr click))
				   (lambda (domain)
				     (wse--view-clicks domain))
				   (cadr click))))
			(list "" ""))
		      (or (elt countries i) (list "" ""))))
    
     (list
      (list
       (caar (wse-sel "select count(*) from clicks where time > ?" time))
       (buttonize "Total Clicks" #'wse--view-total-clicks)
       (caar (wse-sel "select count(distinct country) from views where time > ?"
		      time))
       (buttonize "Total Countries" #'wse--view-total-countries))))))

(defvar-keymap wse-clicks-mode-map
  :parent button-map
  "v" #'wse-clicks-view-todays-media
  "q" #'bury-buffer)

(define-derived-mode wse-clicks-mode special-mode
  :interactive nil
  (setq truncate-lines t))

(defvar wse--shown-media (make-hash-table :test #'equal))

(defun wse-clicks-view-todays-media ()
  "View today's media clicks."
  (interactive nil wse-clicks-mode)
  (let* ((objects
	  (save-excursion
	    (goto-char (point-min))
	    (vtable-objects (vtable-current-table))))
	 (urls (cl-loop for (_ url) in objects
			when (and (and (wse--media-p url)
				       (not (string-match "[.]mp4\\'" url)))
				  (string-match-p
				   (format-time-string "/uploads/%Y/%m/")
				   url)
				  (not (gethash url wse--shown-media)))
			collect url)))
    (unless urls
      (error "No URLs today"))
    (dolist (url urls)
      (setf (gethash url wse--shown-media) t))
    ;; This code doesn't really make sense in general, so it should be
    ;; factored out.
    (let ((browse-url-browser-function browse-url-secondary-browser-function))
      (browse-url (pop urls))
      (sleep-for 2)
      (when urls
	(let ((browse-url-firefox-program "/usr/local/bin/firefox/firefox"))
	  (dolist (url urls)
	    (browse-url url)))))))

(defun wse--view-clicks (domain)
  (switch-to-buffer "*Clicks*")
  (wse-clicks-mode)
  (let ((inhibit-read-only t))
    (setq truncate-lines t)
    (erase-buffer)
    (make-vtable
     :face 'wse
     :columns '((:name "" :align 'right)
		(:name "Clicks"))
     :objects (wse-sel "select count(click), click from clicks where time > ? and domain = ? group by click order by count(click) desc"
		       (wse--24h) domain)
     :getter
     (lambda (elem column vtable)
       (if (equal (vtable-column vtable column) "Clicks")
	   (wse--possibly-buttonize (elt elem column))
	 (elt elem column)))
     :keymap wse-clicks-mode-map)))

(defun wse--view-total-views (_ &optional date)
  (unless date
    (switch-to-buffer "*Total WSE*"))
  (let ((inhibit-read-only t)
	(from (wse--24h))
	(to (wse--future)))
    (if date
	(setq from (concat date " 00:00:00")
	      to (concat date " 23:59:59"))
      (setq truncate-lines t)
      (erase-buffer))
    (make-vtable
     :use-header-line (not date)
     :face 'wse
     :columns '((:name "" :align 'right)
		(:name "Blog" :max-width 20)
		(:name "Posts & Pages"))
     :objects (wse-sel "select count(page), blog, title, page from views where time > ? and time <= ? group by page order by count(page) desc, id"
		       from to)
     :getter
     (lambda (elem column vtable)
       (if (equal (vtable-column vtable column) "Posts & Pages")
	   (buttonize (wse--pretty-url (elt elem column))
		      #'wse--browse (elt elem 2) (elt elem 2))
	 (elt elem column)))
     :keymap wse-mode-map)))

(defun wse--view-total-referrers (_ &optional date)
  (unless date
    (switch-to-buffer "*Total WSE*"))
  (let ((inhibit-read-only t)
	(from (wse--24h))
	(to (wse--future)))
    (if date
	(setq from (concat date " 00:00:00")
	      to (concat date " 23:59:59"))
      (setq truncate-lines t)
      (erase-buffer))
    (make-vtable
     :use-header-line (not date)
     :face 'wse
     :columns '((:name "" :align 'right)
		(:name "Referrers"))
     :objects (wse--transform-referrers
	       (wse-sel "select count(referrer), referrer from referrers where time > ? and time <= ? group by referrer order by count(referrer) desc"
			from to))
     :getter
     (lambda (elem column vtable)
       (if (equal (vtable-column vtable column) "Referrers")
	   (wse--possibly-buttonize (elt elem column))
	 (elt elem column)))
     :keymap wse-mode-map)))

(defun wse--view-total-clicks (_ &optional date)
  (unless date
    (switch-to-buffer "*Total WSE*"))
  (let ((inhibit-read-only t)
	(from (wse--24h))
	(to (wse--future)))
    (if date
	(setq from (concat date " 00:00:00")
	      to (concat date " 23:59:59"))
      (setq truncate-lines t)
      (erase-buffer))
    (make-vtable
     :use-header-line (not date)
     :face 'wse
     :columns '((:name "" :align 'right)
		(:name "Clicks"))
     :objects (wse-sel "select count(distinct click), click from clicks where time > ? and time <= ? group by click order by count(click) desc"
		       from to)
     :getter
     (lambda (elem column vtable)
       (if (equal (vtable-column vtable column) "Clicks")
	   (wse--possibly-buttonize (elt elem column))
	 (elt elem column)))
     :keymap wse-mode-map)))

(defun wse--view-total-countries (_ &optional date)
  (unless date
    (switch-to-buffer "*Total WSE*"))
  (let ((inhibit-read-only t)
	(from (wse--24h))
	(to (wse--future)))
    (if date
	(setq from (concat date " 00:00:00")
	      to (concat date " 23:59:59"))
      (setq truncate-lines t)
      (erase-buffer))
    (make-vtable
     :use-header-line (not date)
     :face 'wse
     :columns '((:name "" :align 'right)
		(:name "Countries"))
     :objects (wse-sel "select count(country), name, code from views, countries where time > ? and time <= ? and views.country = countries.code group by country order by count(country) desc"
		       from to)
     :getter
     (lambda (elem column vtable)
       (if (equal (vtable-column vtable column) "Countries")
	   (wse--countrify (elt elem 2) (elt elem column))
	 (elt elem column)))
     :keymap wse-mode-map)))

(defun wse--transform-referrers (referrers &optional summarize)
  (let ((table (make-hash-table :test #'equal)))
    (cl-loop for (count url) in referrers
	     for trans = (wse--transform-referrer url summarize)
	     ;; OK, OK, this is stupid, but...
	     do (cl-loop repeat count
			 do (push url (gethash trans table nil))))
    (let ((result nil))
      (maphash (lambda (referrer urls)
		 (let ((length (length urls)))
		   (cond
		    ((= (elt referrer 0) ?-)
		     (if (= (length (seq-uniq urls #'equal)) 1)
			 (push (list length (car urls) urls) result)
		       (push (list
			      length
			      (concat "🔽 "
				      (buttonize
				       (substring referrer 1)
				       (lambda (urls)
					 (wse--view-referrer-details urls))
				       urls))
			      urls)
			     result)))
		    (t
		     (push (list length referrer urls) result)))))
	       table)
      (let ((list (nreverse (sort result #'car-less-than-car))))
	(if summarize
	    (seq-take list wse-entries)
	  list)))))

(defun wse--transform-referrer (url &optional summarize)
  (cond
   ((string-match-p "[.]bing[.][a-z]+/\\'" url)
    (if summarize "Search" "Bing"))
   ((string-match-p "[.]google[.][.a-z]+[/]?\\'" url)
    (if summarize "Search" "Google"))
   ((string-match-p "[.]reddit[.]com/\\'" url)
    "Reddit")
   ((string-match-p "[.]?bsky[.]app/\\'" url)
    "Bluesky")
   ((string-match-p "search[.]brave[.]com/\\'" url)
    (if summarize "Search" "Brave"))
   ((string-match-p "\\b[.]?baidu[.]com/" url)
    (if summarize "Search" "Baidu"))
   ((string-match-p "\\b[.]?presearch[.]com/" url)
    (if summarize "Search" "Presearch"))
   ((string-match-p "[a-z]+[.]wikipedia[.]org/\\'" url)
    "Wikipedia")
   ((string-match-p "search[.]yahoo[.]com/\\'" url)
    (if summarize "Search" "Brave"))
   ((string-match-p "\\bduckduckgo[.]com/\\'" url)
    (if summarize "Search" "DuckDuckGo"))
   ((string-match-p "\\byandex[.]ru/\\|\\bya.ru/" url)
    (if summarize "Search" "Yandex"))
   ((string-match-p "\\b[.]qwant[.]com/\\'" url)
    (if summarize "Search" "Qwant"))
   ((string-match-p "\\b[.]?kagi[.]com/\\'" url)
    (if summarize "Search" "Kagi"))
   ((string-match-p "\\b[.]ecosia[.]org/\\'" url)
    (if summarize "Search" "Ecosia"))
   ((and summarize (string-match-p "\\byandex[.]ru/" url))
    "Search")
   ((and summarize (string-match-p "\\ampproject[.]org/" url))
    "Amp")
   ((equal (wse--host url) "t.co")
    "Twitter")
   ((equal (wse--get-domain (wse--host url)) "facebook.com")
    "Facebook")
   ((and summarize (member (wse--host url) wse-blogs))
    "Interblog")
   (summarize
    (concat "-" (wse--get-domain (wse--host url))))
   (t
    url)))

;; Plots.

(defun wse--plot-blogs-today ()
  (let ((data 
	 (wse-sel "select blog, count(blog), count(distinct ip) from views where time > ? group by blog order by blog"
		  (wse--24h))))
    (insert-image
     (svg-image
      (eplot-make-plot
       `((Format horizontal-bar-chart)
	 (Color vary)
	 (Mode dark)
	 (Layout compact)
	 (Font ,wse-font)
	 (Margin-Left 10)
	 (Horizontal-Label-Left 20)
	 (Horizontal-Label-Font-Size 18)
	 (Height 300)
	 (Width 250))
       (append
	'((Bar-Max-Width: 40))
	(cl-loop for (blog views _visitors) in data
		 collect (list views "# Label: " blog)))
       (append
	'((Bar-Max-Width: 20)
	  (Color: "#004000"))
	(cl-loop for (blog _views visitors) in data
		 collect (list visitors "# Label: " blog)))))
     "*")))

(defun wse--plot-history ()
  (let ((data (wse-sel "select date, sum(views), sum(visitors) from history group by date order by date limit 14"))
	(today (car (wse-sel "select count(*), count(distinct ip) from views where time > ?"
			     (wse--24h))))
	(current (car (wse-sel "select count(*), count(distinct ip) from views where time > ?"
			       (format-time-string "%Y-%m-%d 00:00:00")))))
    (insert-image
     (svg-image
      (eplot-make-plot
       `((Mode dark)
	 (Layout compact)
	 (Font ,wse-font)
	 (Height 300)
	 (Width 550)
	 (Format bar-chart))
       (append
	'((Bar-Max-Width: 20)
	  (Color: "#004000"))
	(cl-loop for (date _views visitors) in data
		 collect (list visitors "# Label: " (substring date 8)))
	(list (list (cadr current) "# Label: " (format-time-string "%d")))
	(list (list (cadr today) "# Label: 24h")))
       (append
	'((Bar-Max-Width: 40)
	  (Color: "#008000"))
	(cl-loop for (date views _visitors) in data
		 collect (list views "# Label: " (substring date 8)))
	(list (list (car current) "# Label: " (format-time-string "%d")))
	(list (list (car today) "# Label: 24h")))))
     "*")))

(provide 'wse)

;;; wse.el ends here

;; check history summary
;; Rewrite Search detect
