;;;; filesystem.lisp --- Files and Directories
;;;;
;;;; Copyright (C) 2020 GrammaTech, Inc.
;;;;
;;;; This code is licensed under the MIT license. See the LICENSE.txt
;;;; file in the project root for license terms.
;;;;
;;;; This project is sponsored by the Office of Naval Research, One
;;;; Liberty Center, 875 N. Randolph Street, Arlington, VA 22203 under
;;;; contract # N68335-17-C-0700.  The content of the information does
;;;; not necessarily reflect the position or policy of the Government
;;;; and no official endorsement should be inferred.
;;;;
;;;;
;;;; Functions for working with file and directories.  Includes
;;;; functions for efficient serialization to/from files as well as
;;;; functions for creating and using temporary files and directories.
;;;;
(uiop/package:define-package :gt/filesystem
  (:use-reexport :uiop/filesystem :uiop/pathname)
  (:use :common-lisp :alexandria :serapeum :iterate)
  (:shadowing-import-from :iterate
                          ;; Shadow serapeum macros.
                          :summing :collecting :sum :in)
  (:import-from :split-sequence :split-sequence)
  (:import-from :uiop/run-program :run-program)
  (:import-from :uiop/os :getcwd)
  (:import-from :uiop/filesystem :with-current-directory)
  (:import-from :uiop/stream
                :default-temporary-directory)
  (:import-from :asdf-encodings
                :detect-file-encoding
                :encoding-external-format)
  (:import-from :osicat :file-permissions :pathname-as-directory)
  (:export
   :file-mime-type
   :file-to-string
   :file-to-bytes
   :string-to-file
   :bytes-to-file
   ;; Temporary files
   :*temp-dir*
   :with-temp-file
   :with-temp-file-of
   :with-temp-dir
   :with-temp-dir-of
   :with-temp-fifo
   :temp-file-name
   :delete-path
   :pathname-relativize
   :truenamestring
   :in-directory
   :directory-p
   ;; cl-fad
   :merge-pathnames-as-file
   :merge-pathnames-as-directory
   :canonical-pathname
   :directory-wildcard
   :list-directory
   :walk-directory
   ;; Other filename/pathname.
   :getcwd
   :with-current-directory
   :file-permissions
   :pathname-as-directory))
(in-package :gt/filesystem)

(defun file-mime-type (path)
  "Return the mime type of PATH as a list of two symbols.
The Unix `file' command is used, specifically \"file -b --mime-type PATH\"."
  (assert (probe-file path) (path) "No file or directory at ~S" path)
  (nest (mapcar #'intern) (split-sequence #\/) (string-upcase) (trim-whitespace)
        (run-program (format nil "file -b --mime-type ~a" (namestring path)))))

(defun file-to-string
    (filespec &key (external-format
                    (encoding-external-format (detect-file-encoding filespec))))
  "Return the contents of FILESPEC as a string."
  #+ccl (declare (ignorable external-format))
  (labels
      ((run-read ()
         (let (#+sbcl (sb-impl::*default-external-format* external-format)
                      #+ecl (ext:*default-external-format* external-format)
                      (element-type (case external-format
                                      (:ascii 'base-char)
                                      (t 'character))))
           (with-open-file (in filespec :element-type element-type)
             (let* ((file-bytes (file-length in))
                    (seq (make-string file-bytes :element-type element-type))
                    (file-chars (read-sequence seq in)))
               (if (= file-bytes file-chars)
                   seq
                   ;; Truncate the unused tail of seq.  It is possible
                   ;; for read-sequence to read less than file-length
                   ;; when the file has multi-byte UTF-8 characters.
                   (subseq seq 0 file-chars)))))))

    (restart-case
        (if (member external-format '(:utf8 :utf-8))
            (run-read)
            (handler-case
                (run-read)
              (stream-error (c)
                ;; Try utf-8 as a default fallback.
                (declare (ignorable c))
                (setf external-format :utf-8)
                (run-read))))
      (use-encoding (encoding)
        :report "Specify another encoding."
        (setf external-format encoding)
        (run-read)))))

(declaim (ftype (function ((or string pathname))
                          (simple-array (unsigned-byte 8)))
                file-to-bytes))
(defun file-to-bytes (filespec)
  "Return the contents of FILESPEC as a byte array."
  (with-open-file (in filespec :element-type '(unsigned-byte 8))
    (let ((seq (make-array (file-length in) :element-type '(unsigned-byte 8))))
      (read-sequence seq in)
      seq)))

(define-condition file-access (error)
  ((file-access-path :initarg :path :initform nil
                     :reader file-access-path)
   (file-access-operation :initarg :operation :initform nil
                          :reader file-access-operation))
  (:report (lambda (condition stream)
             (format stream "Unable to ~a file ~a"
                     (file-access-operation condition)
                     (file-access-path condition)))))

;;; TODO: Replace with `alexandria:write-string-into-file'?
(defun string-to-file (string filespec &key
                                         (if-exists :supersede)
                                         (external-format :default))
  "Write STRING to FILESPEC.
Restarts available to handle cases where FILESPEC is not writable,
SET-FILE-WRITABLE, and where the appropriate encoding is not used,
USE-ENCODING. "
  (setf filespec (if (probe-file filespec) (truename filespec) filespec))
  (labels ((run-write ()
             (ensure-directories-exist filespec)
             (with-open-file (out filespec :direction :output
                                  :if-exists if-exists
                                  :external-format external-format)
               (format out "~a" string))))

    (when (and (file-exists-p filespec)
               (not (member :user-write (file-permissions filespec))))
      (restart-case
          (error (make-condition 'file-access
                                 :path filespec
                                 :operation :write))
        (set-file-writable ()
          (format nil "Forcefully set ~a to be writable" filespec)
          (push :user-write (file-permissions filespec)))))

    (restart-case
        (if (member external-format '(:utf8 :utf-8))
            (run-write)
            (handler-case
                (run-write)
              (stream-error (c)
                ;; Try utf-8 as a default fallback.
                (declare (ignorable c))
                (setf external-format :utf-8)
                (run-write))))
      (use-encoding (encoding)
        :report "Specify another encoding."
        (setf external-format encoding)
        (run-write))))
  filespec)

(defun bytes-to-file (bytes filespec &key (if-exists :supersede))
  "Write BYTES to FILESPEC"
  (with-open-file (out filespec :element-type '(unsigned-byte 8)
                       :direction :output :if-exists if-exists)
    (write-sequence bytes out)))

(defun pathname-relativize (root-path path)
  "Return PATH relative to ROOT-PATH."
  (string-replace-all
   (namestring (canonical-pathname path))
   (namestring (canonical-pathname (ensure-directory-pathname root-path)))
   ""))


;;; Temporary files
(defmacro with-temp-file (spec &rest body)
  "SPEC holds the variable used to reference the file w/optional extension.
After BODY is executed the temporary file is removed."
  (with-gensyms (v)
    `(let* ((,v ,(second spec))
            (,(car spec) (temp-file-name ,v)))
       (unwind-protect (progn ,@body) (delete-path ,(car spec))))))

(defmacro with-temp-file-of ((variable &optional type) string &rest body)
  "Execute BODY with STRING in a temporary file whose path is in VARIABLE."
  `(let ((,variable (temp-file-name ,type)))
     (unwind-protect (progn (string-to-file ,string ,variable) ,@body)
       (when (probe-file ,variable) (delete-file ,variable)))))

(defmacro with-temp-dir (spec &rest body)
  "Execute BODY with a temporary directory.
The first form passed to `with-temp-dir' is passed through
to `with-temp-file' to create path to the temporary directory."
  `(with-temp-file ,spec
     (setf ,(car spec) (namestring (ensure-directory-pathname ,(car spec))))
     (ensure-directories-exist ,(car spec))
     ,@body))

(defmacro with-temp-dir-of (spec dir &rest body)
  "Populate SPEC with the path to a temporary directory with the contents
of DIR and execute BODY"
  `(with-temp-dir ,spec
     (run-program (format nil "cp -pr ~a/. ~a"
                              (namestring ,dir)
                              (namestring ,(car spec))))
     ,@body))

(defmacro with-temp-fifo (spec &rest body)
  "Execute BODY with a temporary fifo.
The first form passed to `with-temporary-fifo' is passed through to
`with-temp-file' to create path to the temporary fifo."
  `(with-temp-file ,spec
     (delete-path ,(car spec))
     #-windows (osicat-posix:mkfifo ,(car spec) (logior osicat-posix:s-iwusr
                                                        osicat-posix:s-irusr))
     ,@body))

(defvar *temp-dir* (namestring (default-temporary-directory))
  "Set to non-nil for a custom temporary directory.")

(defun temp-file-name (&optional type)
  (let ((base
          #+clisp
          (let ((stream (gensym)))
            (eval `(with-open-stream
                       (,stream (ext:mkstemp
                                 (if *temp-dir*
                                     (namestring (make-pathname
                                                  :directory *temp-dir*
                                                  :name "XXXXXX"))
                                     nil)))
                     (namestring (pathname ,stream)))))
          #+(or sbcl ccl ecl)
          (tempnam *temp-dir* nil)
          #+allegro
          (system:make-temp-file-name nil *temp-dir*)
          #-(or sbcl clisp ccl allegro ecl)
          (error "no temporary file backend for this lisp.")))
    (concatenate 'string base "." (or type ""))))

#+sbcl
(locally (declare (sb-ext:muffle-conditions sb-ext:compiler-note))
  (sb-alien:define-alien-routine (#-win32 "tempnam" #+win32 "_tempnam" tempnam)
      sb-alien:c-string
    (dir sb-alien:c-string)
    (prefix sb-alien:c-string)))

#+(and ccl linux)
(defun tempnam (dir prefix)
  (ccl:with-filename-cstrs ((base dir) (prefix (or prefix "")))
    (ccl:get-foreign-namestring
     (ccl:external-call "tempnam" :address base :address prefix :address))))

#+(and ccl windows)
(defun tempnam (dir prefix)
  (ccl:with-filename-cstrs ((base (or dir "")) (prefix (or prefix "")))
    (ccl:%get-cstring
     (ccl:external-call "_tempnam" :address
                        base :address
                        prefix :address))))

#+ecl
(defun tempnam (dir &optional prefix)
  (let ((dir-name (uiop:ensure-directory-pathname
                   (or dir *temporary-directory*))))
    (ext:mkstemp (if prefix
                     (uiop::merge-pathnames dir-name prefix)
                     dir-name))))

(defun delete-path (path)
  "Delete anything (file or directory) at PATH."
  (let ((probe (probe-file path)))
    (when probe
      (if (equal (directory-namestring probe)
                 (namestring probe))
          (delete-directory-tree (ensure-directory-pathname probe)
           :validate t)
          (delete-file path)))))

(defun directory-p (pathname)
  "Return a directory version of PATHNAME if it indicates a directory."
  (cond
    ((directory-pathname-p pathname) pathname)
    ;; Wild pathnames are not directory pathnames.
    ;; Also, `directory-exists-p' faults on wild pathnames.
    ((wild-pathname-p pathname) nil)
    ;; `directory-exists-p' (like this function) returns the pathname.
    (t (directory-exists-p (pathname-as-directory pathname)))))


;;;; Utilities from cl-fad.
;;;
;;; The functions `merge-pathnames-as-file', `merge-pathnames-as-directory',
;;; `canonical-pathname', `directory-wildcard', `list-directory', and
;;; `walk-directory' were adapted from cl-fad.  The CL-FAD license applies
;;; to the source for these functions and is included below:
;;;
;;; Copyright (c) 2004, Peter Seibel.  All rights reserved.
;;; Copyright (c) 2004-2010, Dr. Edmund Weitz.  All rights reserved.
;;;
;;; Redistribution and use in source and binary forms, with or without
;;; modification, are permitted provided that the following conditions
;;; are met:
;;;
;;;   * Redistributions of source code must retain the above copyright
;;;     notice, this list of conditions and the following disclaimer.
;;;
;;;   * Redistributions in binary form must reproduce the above
;;;     copyright notice, this list of conditions and the following
;;;     disclaimer in the documentation and/or other materials
;;;     provided with the distribution.
;;;
;;; THIS SOFTWARE IS PROVIDED BY THE AUTHORS 'AS IS' AND ANY EXPRESSED
;;; OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
;;; WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
;;; ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
;;; DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
;;; DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE
;;; GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
;;; INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
;;; WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
;;; NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
;;; SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
;;;
(defun canonical-pathname (path)
  "Remove redundant information from PATH."
  (iter (with full-dir = (or (pathname-directory (pathname path))
                             (list :relative)))
        (with canon-dir = (if (member (first full-dir) '(:relative :absolute))
                              (list (pop full-dir))
                              (list :relative)))
        (while full-dir)
        (cond ((string= "." (first full-dir))
               (pop full-dir))
              ((eql :back (second full-dir))
               (pop full-dir)
               (pop full-dir))
              (t (push (pop full-dir) canon-dir)))
        (finally (return (make-pathname :defaults (pathname path)
                                        :directory (nreverse canon-dir))))))

(defun merge-pathnames-as-directory (&rest pathnames)
  "Given a list of pathnames, this returns a single
directory pathname containing the logical concatenation of them all."
  (if (null pathnames)
      (make-pathname)
      (let* ((pathnames (mapcar #'pathname pathnames))
             (defaults (first pathnames))
             (dir (pathname-directory defaults)))
        (make-pathname
          :defaults defaults
          :directory (iter (for pathname in (rest pathnames))
                           (for directory = (pathname-directory pathname))
                           (cond ((eq :absolute (first directory))
                                  (setf dir directory))
                                 ((eq :relative (first directory))
                                  (setf dir (append dir (rest directory)))))
                           (finally (return dir)))
          :name nil :type nil))))

(defun merge-pathnames-as-file (&rest pathnames)
  "Given a list of pathnames returns a single filename pathname
containing the logical concatenation of them all."
  (if (null pathnames)
      (make-pathname)
      (let ((file-name (first (last pathnames))))
        (make-pathname :defaults (apply #'merge-pathnames-as-directory pathnames)
                       :name (pathname-name file-name)
                       :type (pathname-type file-name)
                       :version (pathname-version file-name)))))

(defun directory-wildcard (dirname)
  "Returns a wild pathname designator that designates all files within
the directory named by the non-wild pathname designator DIRNAME."
  (when (wild-pathname-p dirname)
    (error "Can only make wildcard directories from non-wildcard directories."))
  (make-pathname :name #-:cormanlisp :wild #+:cormanlisp "*"
                 :type #-(or :clisp :cormanlisp) :wild
                       #+:clisp nil
                       #+:cormanlisp "*"
                 :defaults (pathname-as-directory dirname)))

(defun list-directory (dirname &key (follow-symlinks t))
  "Returns a fresh list of pathnames corresponding to all files within
the directory named by the non-wild pathname designator DIRNAME.
The pathnames of sub-directories are returned in directory form -
see PATHNAME-AS-DIRECTORY.

  If FOLLOW-SYMLINKS is true, then the returned list contains
truenames (symlinks will be resolved) which essentially means that it
might also return files from *outside* the directory.  This works on
all platforms.

  When FOLLOW-SYMLINKS is NIL, it should return the actual directory
contents, which might include symlinks.  Currently this works on SBCL
and CCL."
  (declare (ignorable follow-symlinks))
  (when (wild-pathname-p dirname)
    (error "Can only list concrete directory names."))
  #+(or :ecl :clasp)
  (let ((dir (pathname-as-directory dirname)))
    (concatenate 'list
                 (directory (merge-pathnames (pathname "*/") dir))
                 (directory (merge-pathnames (pathname "*.*") dir))))
  #-(or :ecl :clasp)
  (let ((wildcard (directory-wildcard dirname)))
    #+:abcl (system::list-directory dirname)
    #+:sbcl (directory wildcard :resolve-symlinks follow-symlinks)
    #+(or :cmu :scl :lispworks) (directory wildcard)
    #+(or :openmcl :digitool) (directory wildcard :directories t
                                                  :follow-links follow-symlinks)
    #+:allegro (directory wildcard :directories-are-files nil)
    #+:clisp (nconc (directory wildcard :if-does-not-exist :keep)
                    (directory (clisp-subdirectories-wildcard wildcard)))
    #+:cormanlisp (nconc (directory wildcard)
                         (cl::directory-subdirs dirname)))
  #-(or :sbcl :cmu :scl :lispworks :openmcl :allegro :clisp
        :cormanlisp :ecl :abcl :digitool :clasp)
  (error "LIST-DIRECTORY not implemented"))

(defun walk-directory (dirname fn &key directories
                                       (if-does-not-exist :error)
                                       (test (constantly t))
                                       (follow-symlinks t))
  "Recursively applies the function FN to all files within the
directory named by the non-wild pathname designator DIRNAME and all of
its sub-directories.  FN will only be applied to files for which the
function TEST returns a true value.  If DIRECTORIES is not NIL, FN and
TEST are applied to directories as well.  If DIRECTORIES
is :DEPTH-FIRST, FN will be applied to the directory's contents first.
If DIRECTORIES is :BREADTH-FIRST and TEST returns NIL, the directory's
content will be skipped. IF-DOES-NOT-EXIST must be one of :ERROR
or :IGNORE where :ERROR means that an error will be signaled if the
directory DIRNAME does not exist.  If FOLLOW-SYMLINKS is T, then your
callback will receive truenames.  Otherwise you should get the actual
directory contents, which might include symlinks.  This might not be
supported on all platforms.  See LIST-DIRECTORY."
  (labels ((walk (name)
             (cond
               ((directory-pathname-p name)
                ;; the code is written in a slightly awkward way for
                ;; backward compatibility
                (cond ((not directories)
                       (dolist (file (list-directory name
                                       :follow-symlinks follow-symlinks))
                         (walk file)))
                      ((eql directories :breadth-first)
                       (when (funcall test name)
                         (funcall fn name)
                         (dolist (file (list-directory name
                                         :follow-symlinks follow-symlinks))
                           (walk file))))
                      ;; :DEPTH-FIRST is implicit
                      (t (dolist (file (list-directory name
                                         :follow-symlinks follow-symlinks))
                           (walk file))
                         (when (funcall test name)
                           (funcall fn name)))))
               ((funcall test name)
                (funcall fn name)))))
    (let ((pathname-as-directory (pathname-as-directory dirname)))
      (case if-does-not-exist
        ((:error)
         (cond ((not (directory-exists-p pathname-as-directory))
                (error "File ~S does not exist."
                       pathname-as-directory))
               (t (walk pathname-as-directory))))
        ((:ignore)
         (when (directory-exists-p pathname-as-directory)
           (walk pathname-as-directory)))
        (otherwise
         (error "IF-DOES-NOT-EXIST must be one of :ERROR or :IGNORE."))))
    (values)))
